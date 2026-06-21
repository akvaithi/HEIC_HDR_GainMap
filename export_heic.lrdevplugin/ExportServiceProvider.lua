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
    { key = 'conversionTool', default = 'toGainMapHDR' }, -- Added conversion tool option
    { key = 'addToPhotos', default = false },             -- import the result into Apple Photos
    { key = 'photosAlbum', default = 'Lightroom HDR' },   -- target album name
}

-- Lock the export to the format the HDR pipeline needs, so the user doesn't have to
-- configure the File Settings section by hand.
exportServiceProvider.allowFileFormats = { 'TIFF' }

-- Force a 16-bit, wide-gamut, HDR TIFF intermediary every time this plugin exports.
-- (TIFF is lossless, so there is no quality field to worry about; our own slider
-- drives the HEIC quality.)  Note: LR_export_useHDR is the Lightroom Classic 14 key
-- for the "HDR Output" checkbox; if a future LRC renames it, the runtime guard below
-- still catches a missing HDR export.
exportServiceProvider.updateExportSettings = function( exportSettings )
    exportSettings.LR_format = 'TIFF'
    exportSettings.LR_export_bitDepth = 16
    exportSettings.LR_tiff_compressionMethod = 'compressionMethod_None'
    exportSettings.LR_export_colorSpace = 'ProPhotoRGB' -- widest standard gamut; engine outputs P3
    exportSettings.LR_export_useHDR = true              -- HDR Output on
    exportSettings.LR_minimizeEmbeddedMetadata = false
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
                    title = "Encoder:",
                    alignment = 'right',
                    width = LrView.share 'label_width',
                },
                f:popup_menu {
                    items = {
                        { title = 'Gain Map HDR (recommended)', value = 'toGainMapHDR' },
                        { title = 'Plain HEIC \226\128\147 no HDR (macOS sips)', value = 'sips' },
                    },
                    value = LrView.bind 'conversionTool',
                    tooltip = "Gain Map HDR: 10-bit HEIC with an ISO 21496-1 HDR gain map (this plugin's purpose). "
                        .. "Plain HEIC: a quick macOS sips conversion with no gain map and no HDR.",
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
    local conversionTool = exportContext.propertyTable.conversionTool or 'toGainMapHDR'
    local addToPhotos = exportContext.propertyTable.addToPhotos
    local photosAlbum = exportContext.propertyTable.photosAlbum or 'Lightroom HDR'
    local photosImportList = {} -- HEIC paths to import into Apple Photos at the end

    -- Quality guard: the gain-map engine can only preserve the HDR headroom and gamut
    -- that Lightroom hands it. An 8-bit or non-TIFF intermediary produces a hollow
    -- 10-bit HEIC, so warn (once) if the export isn't 16-bit TIFF with HDR enabled.
    if conversionTool == 'toGainMapHDR' then
        local settings = exportContext.propertyTable
        local fmt = settings.LR_format
        local bitDepth = tonumber(settings.LR_export_bitDepth) or 8
        local hdrOn = settings.LR_export_useHDR
        local issues = {}
        if fmt ~= 'TIFF' then
            table.insert(issues, "- Format is '" .. tostring(fmt) .. "'; use TIFF (it is the HDR intermediary).")
        end
        if bitDepth < 16 then
            table.insert(issues, "- Bit Depth is " .. bitDepth .. "-bit; use 16-bit so the 10-bit HEIC has real precision.")
        end
        if hdrOn == false then
            table.insert(issues, "- HDR Output is off; enable it (and disable 'Maximum Compatibility').")
        end
        if #issues > 0 then
            local choice = LrDialogs.confirm(
                "Export settings may limit HDR quality",
                "For best 10-bit ISO 21496-1 HDR results:\n\n" .. table.concat(issues, "\n") ..
                "\n\nExport wide-gamut (Display P3 or Rec. 2020) for the richest highlights.",
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

            local command
            if conversionTool == 'toGainMapHDR' then
                local pluginPath = LrPathUtils.child(_PLUGIN.path, "toGainMapHDR")
                local destFolder = LrPathUtils.parent(heicPath)
                -- ISO 21496-1 adaptive gain map (default path), 10-bit Main 10 base, full-resolution RGB gain map
                command = string.format('"%s" "%s" "%s" -q %.2f -d 10', pluginPath, pathOrMessage, destFolder, imageQuality/100)

            elseif conversionTool == 'sips' then
                command = string.format('sips -s format heic -s formatOptions %s -o "%s" "%s"', imageQuality, heicPath, pathOrMessage)
            end

            -- Display the command in debug dialog
            -- LrDialogs.message("Command to execute", command)
            
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
