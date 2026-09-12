-- Raycast Script Command
-- @raycast.schemaVersion 1
-- @raycast.title Search Vela
-- @raycast.mode fullOutput
-- @raycast.packageName Vela
-- @raycast.argument1 { "type": "text", "placeholder": "Engineering evidence" }
on run argv
    set queryText to item 1 of argv
    set velaPath to "/Applications/Vela.app/Contents/MacOS/vela"
    return do shell script quoted form of velaPath & " search " & quoted form of queryText
end run
