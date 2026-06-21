local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrPathUtils = import 'LrPathUtils'
local LrExportSession = import 'LrExportSession'
local LrFileUtils = import 'LrFileUtils'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrProgressScope = import 'LrProgressScope'

local exportServiceProvider = {}

exportServiceProvider.exportPresetFields = {
    { key = 'imageQuality', default = 85 }, -- 85 is the HDR sweet spot; HEVC artifacts show in highlights below this
    { key = 'addToPhotos', default = false },             -- import the result into Apple Photos
    { key = 'photosAlbum', default = 'Lightroom HDR' },   -- target album name
}

-- Lock the export to the format the HDR pipeline needs.
exportServiceProvider.allowFileFormats = { 'TIFF' }

-- Force the parts of the intermediary the HDR pipeline depends on, every export:
--   16-bit depth, HDR Output on, and Maximize Compatibility off.
-- Color space (gamut) is intentionally left untouched so it stays user-selectable
-- in the File Settings section.
-- Note: LR_export_useHDR / LR_export_maximizeCompatibility are the Lightroom Classic 14
-- HDR keys; if a future LRC renames them, the runtime guard below still catches a
-- non-HDR export.
exportServiceProvider.updateExportSettings = function( exportSettings )
    exportSettings.LR_format = 'TIFF'
    exportSettings.LR_export_bitDepth = 16
    exportSettings.LR_tiff_compressionMethod = 'compressionMethod_None'
    exportSettings.LR_export_useHDR = true                 -- HDR Output on
    exportSettings.LR_export_maximizeCompatibility = false -- do not bake an SDR-compat copy
end


exportServiceProvider.sectionsForTopOfDialog = function(viewFactory, propertyTable)
    local f = viewFactory

    -- Ensure imageQuality is an integer
    propertyTable:addObserver('imageQuality', function()
        propertyTable.imageQuality = math.floor(propertyTable.imageQuality + 0.5)
    end)

    return {
        {
            title = "HEIC Export Options",
            f:row {
                f:static_text {
                    title = "Image Quality:",
                    alignment = 'right',
                    width = LrView.share 'label_width',
                },
                f:slider {
                    value = LrView.bind 'imageQuality',
                    min = 0,
                    max = 100,
                    width_in_chars = 20,
                    fill_horizontal = 1,
                },
                f:edit_field {
                    value = LrView.bind 'imageQuality',
                    width_in_chars = 3,
                },
            },
            f:row {
                f:static_text {
                    title = "Apple Photos:",
                    alignment = 'right',
                    width = LrView.share 'label_width',
                },
                f:checkbox {
                    title = "Add exported HEIC to album",
                    value = LrView.bind 'addToPhotos',
                },
                f:edit_field {
                    value = LrView.bind 'photosAlbum',
                    width_in_chars = 20,
                    enabled = LrView.bind 'addToPhotos',
                    tooltip = "The album is created in Photos if it doesn't exist. "
                        .. "macOS will ask for permission to control Photos the first time.",
                },
            },
        },
    }
end

exportServiceProvider.processRenderedPhotos = function(functionContext, exportContext)
    local exportSession = exportContext.exportSession
    local nPhotos = exportSession:countRenditions()
    local progressScope = LrProgressScope({
        title = 'Exporting to HEIC',
        functionContext = functionContext
    })

    local imageQuality = exportContext.propertyTable.imageQuality or 85
    local addToPhotos = exportContext.propertyTable.addToPhotos
    local photosAlbum = exportContext.propertyTable.photosAlbum or 'Lightroom HDR'
    local photosImportList = {} -- HEIC paths to import into Apple Photos at the end

    -- Backstop: the settings above are forced in updateExportSettings, but if a future
    -- Lightroom renames a key, warn (rather than silently produce a hollow HEIC) when the
    -- intermediary isn't 16-bit TIFF with HDR output on.
    do
        local settings = exportContext.propertyTable
        local fmt = settings.LR_format
        local bitDepth = tonumber(settings.LR_export_bitDepth) or 8
        local hdrOn = settings.LR_export_useHDR
        local issues = {}
        if fmt ~= 'TIFF' then
            table.insert(issues, "- Format is '" .. tostring(fmt) .. "'; it must be TIFF (the HDR intermediary).")
        end
        if bitDepth < 16 then
            table.insert(issues, "- Bit Depth is " .. bitDepth .. "-bit; it must be 16-bit for real 10-bit precision.")
        end
        if hdrOn == false then
            table.insert(issues, "- HDR Output is off; it must be on (with 'Maximize Compatibility' off).")
        end
        if #issues > 0 then
            local choice = LrDialogs.confirm(
                "Export settings may limit HDR quality",
                "The plugin couldn't force these for 10-bit ISO 21496-1 HDR:\n\n" .. table.concat(issues, "\n"),
                "Continue anyway", "Cancel")
            if choice == 'cancel' then
                progressScope:done()
                return
            end
        end
    end

    for i, rendition in exportSession:renditions() do
        progressScope:setPortionComplete(i-1, nPhotos)

        local success, pathOrMessage = rendition:waitForRender()
        if success then
            local heicPath = LrPathUtils.replaceExtension(pathOrMessage, "heic")

            local pluginPath = LrPathUtils.child(_PLUGIN.path, "toGainMapHDR")
            local destFolder = LrPathUtils.parent(heicPath)
            -- ISO 21496-1 adaptive gain map (default path), 10-bit Main 10 base, full-resolution RGB gain map
            local command = string.format('"%s" "%s" "%s" -q %.2f -d 10', pluginPath, pathOrMessage, destFolder, imageQuality/100)

            local result, output = LrTasks.execute(command, {captureStdout = true})
            if result ~= 0 then
                LrDialogs.showError("Failed to convert to HEIC. Error: " .. (output or "Unknown error"))
            else
                -- Display successful output for debugging
                -- LrDialogs.message("Command Successful", "Output: " .. (output or "No output"))
                LrFileUtils.delete(pathOrMessage)
                if addToPhotos and LrFileUtils.exists(heicPath) then
                    table.insert(photosImportList, heicPath)
                end
            end
        else
            LrDialogs.showError("Error rendering photo: " .. tostring(pathOrMessage))
        end

        progressScope:setPortionComplete(i, nPhotos)
        if progressScope:isCanceled() then break end
    end

    -- Import the exported HEICs into an Apple Photos album (one batch = one permission prompt).
    if addToPhotos and #photosImportList > 0 then
        progressScope:setCaption("Adding to Photos album: " .. photosAlbum)

        -- Escape a Lua string for use as an AppleScript double-quoted literal.
        local function asEsc(s)
            return (tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"'))
        end
        -- Escape a Lua string for a single-quoted shell argument.
        local function shEsc(s)
            return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
        end

        local fileItems = {}
        for _, p in ipairs(photosImportList) do
            table.insert(fileItems, 'POSIX file "' .. asEsc(p) .. '"')
        end

        local album = asEsc(photosAlbum)
        local script = table.concat({
            'tell application "Photos"',
            '  set theAlbum to missing value',
            '  repeat with a in albums',
            '    if name of a is "' .. album .. '" then',
            '      set theAlbum to a',
            '      exit repeat',
            '    end if',
            '  end repeat',
            '  if theAlbum is missing value then set theAlbum to (make new album named "' .. album .. '")',
            '  import {' .. table.concat(fileItems, ', ') .. '} into theAlbum',
            'end tell',
        }, '\n')

        local cmd = 'osascript -e ' .. shEsc(script)
        local result, output = LrTasks.execute(cmd, { captureStdout = true })
        if result ~= 0 then
            LrDialogs.message(
                "Couldn't add photos to the Photos album",
                "The HEIC files were exported successfully, but importing them into Photos failed.\n\n" ..
                "Make sure Lightroom is allowed to control Photos in System Settings \226\134\146 Privacy & Security \226\134\146 Automation.\n\n" ..
                "Details: " .. (output or "unknown error"),
                "warning")
        end
    end

    progressScope:done()
end

return exportServiceProvider
