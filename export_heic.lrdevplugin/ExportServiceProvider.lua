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
}



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
                    title = "Conversion Tool:",
                    alignment = 'right',
                    width = LrView.share 'label_width',
                },
                f:popup_menu {
                    items = {
                        { title = 'Default', value = 'toGainMapHDR' },
                        { title = 'MacOS SIPS(Only HEIC)', value = 'sips' },
                    },
                    value = LrView.bind 'conversionTool',
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
            end
        else
            LrDialogs.showError("Error rendering photo: " .. tostring(pathOrMessage))
        end

        progressScope:setPortionComplete(i, nPhotos)
        if progressScope:isCanceled() then break end
    end
    progressScope:done()
end

return exportServiceProvider
