-- Native test driver for window.luau's CHOOSE_FOLDER subprocess; never an app-name match.
-- Usage: osascript e2e_picker_macos.applescript OWNER_PID select ABSOLUTE_FOLDER [TIMEOUT_SECONDS]
--        osascript e2e_picker_macos.applescript OWNER_PID cancel '' [TIMEOUT_SECONDS]
-- Requires a logged-in macOS GUI session, Accessibility permission for the process
-- running this script, and Automation permission to control System Events. No Finder
-- automation is used. The chooser must expose its UI under its own osascript PID.
-- This script is intentionally not executable/verified on the Windows test host.

property ownerPID : 0
property pickerPID : 0
property deadline : missing value
property timeoutSeconds : 20
property currentStage : "validating arguments"

on run argv
	try
		if (count argv) < 3 or (count argv) > 4 then error "Usage: osascript e2e_picker_macos.applescript OWNER_PID select|cancel ABSOLUTE_FOLDER_OR_EMPTY [TIMEOUT_SECONDS]"
		set ownerPID to my positivePID(item 1 of argv)
		set requestedAction to item 2 of argv
		set folderPath to item 3 of argv
		if requestedAction is not "select" and requestedAction is not "cancel" then error "Action must be select or cancel."
		if (count argv) = 4 then set timeoutSeconds to (item 4 of argv) as real
		if timeoutSeconds ≤ 0 then error "TimeoutSeconds must be positive."
		if requestedAction = "select" then
			if folderPath does not start with "/" then error "Selection requires an absolute POSIX folder path."
			try
				set selectedFolder to (POSIX file folderPath) as alias
				set folderInfo to info for selectedFolder
				if not (folder of folderInfo) then error "The selection is not a directory."
			on error validationMessage
				error "Invalid or inaccessible selection folder: " & folderPath & ". " & validationMessage
			end try
		else if folderPath is not "" then
			error "Cancel requires an empty folder argument."
		end if

		set deadline to (current date) + timeoutSeconds
		-- Also bound individual Apple events, including blocked permission prompts.
		with timeout of timeoutSeconds seconds
			set currentStage to "checking System Events Accessibility and Automation access"
			tell application "System Events"
				if not UI elements enabled then error "Accessibility permission is disabled. Enable the invoking terminal/test host in System Settings > Privacy & Security > Accessibility, then restart it."
			end tell

			set currentStage to "finding the descendant CHOOSE_FOLDER osascript process"
			set pickerPID to my waitForPicker()
			set currentStage to "waiting for the picker process's native folder panel"
			set pickerPanel to my waitForPanel()
			my focusPanel(pickerPanel)

			if requestedAction = "cancel" then
				set currentStage to "cancelling the scoped native folder panel"
				set cancelButton to my axAttribute(pickerPanel, "AXCancelButton")
				if cancelButton is not missing value then
					my pressButton(cancelButton)
				else
					my scopedKey(pickerPanel, "escape")
				end if
			else
				set currentStage to "opening Go to Folder in the scoped native folder panel"
				my scopedKey(pickerPanel, "goToFolder")
				set locationPanel to my waitForLocationPanel(pickerPanel)
				set locationField to my locationEntry(locationPanel)
				if locationField is missing value then error "Go to Folder exposed no editable AX text field."
				-- Set the literal AX value: the folder never enters shell or AppleScript source.
				tell application "System Events" to set value of attribute "AXValue" of locationField to folderPath
				if (my axAttribute(locationField, "AXValue") as text) is not folderPath then error "Go to Folder did not retain the literal requested path."
				set currentStage to "confirming Go to Folder with its accessible default action"
				set goButton to my waitForDefaultButton(locationPanel, pickerPanel)
				my pressButton(goButton)
				set currentStage to "waiting for Go to Folder to close and the folder selection to become ready"
				my waitForLocationClose(pickerPanel)
				set selectButton to my waitForDefaultButton(pickerPanel, missing value)
				set currentStage to "confirming the native folder selection"
				my pressButton(selectButton)
			end if

			set currentStage to "waiting for the native picker subprocess to close"
			my waitForPickerExit()
			return "Native folder picker " & requestedAction & " completed (owner PID " & ownerPID & ", picker PID " & pickerPID & ")."
		end timeout
	on error errorMessage number errorNumber
		my raisePermissionError(errorMessage, errorNumber)
		error "macOS native picker driver failed while " & currentStage & " (owner PID " & ownerPID & ", picker PID " & pickerPID & "): " & errorMessage number 1
	end try
end run

on positivePID(pidText)
	if pidText = "" then error "OwnerPid must be a positive numeric PID."
	repeat with aCharacter in characters of pidText
		if "0123456789" does not contain (aCharacter as text) then error "OwnerPid must contain only decimal digits."
	end repeat
	set resultPID to pidText as integer
	if resultPID ≤ 0 then error "OwnerPid must be positive."
	return resultPID
end positivePID

on checkDeadline()
	if (current date) ≥ deadline then error "Timed out after " & timeoutSeconds & " seconds. Ensure the owner has opened its native picker, the GUI session is unlocked, and no permission prompt is blocking System Events."
end checkDeadline

on pauseUntilNextObservation()
	my checkDeadline()
	-- Poll only after an observed process/UI state has not yet satisfied its condition.
	delay 0.1
end pauseUntilNextObservation

on processSnapshot()
	-- Fixed command; no caller-supplied path or text is interpolated into a shell.
	set processOutput to do shell script "/bin/ps -ww -axo pid=,ppid=,command="
	set processRows to {}
	repeat with processLine in paragraphs of processOutput
		set lineText to processLine as text
		set firstToken to my numberToken(lineText, 1)
		set secondToken to my numberToken(lineText, item 2 of firstToken)
		set commandOffset to item 2 of secondToken
		repeat while commandOffset ≤ (length of lineText)
			if character commandOffset of lineText is not space and character commandOffset of lineText is not tab then exit repeat
			set commandOffset to commandOffset + 1
		end repeat
		if commandOffset ≤ (length of lineText) then
			set end of processRows to {pidValue:item 1 of firstToken, parentValue:item 1 of secondToken, commandValue:text commandOffset thru -1 of lineText}
		end if
	end repeat
	return processRows
end processSnapshot

on numberToken(lineText, startOffset)
	set cursorOffset to startOffset
	repeat while cursorOffset ≤ (length of lineText)
		if character cursorOffset of lineText is not space and character cursorOffset of lineText is not tab then exit repeat
		set cursorOffset to cursorOffset + 1
	end repeat
	set tokenStart to cursorOffset
	repeat while cursorOffset ≤ (length of lineText)
		if "0123456789" does not contain (character cursorOffset of lineText) then exit repeat
		set cursorOffset to cursorOffset + 1
	end repeat
	if cursorOffset = tokenStart then error "Could not parse the macOS process table."
	return {(text tokenStart thru (cursorOffset - 1) of lineText) as integer, cursorOffset}
end numberToken

on rowForPID(processRows, wantedPID)
	repeat with processRow in processRows
		if pidValue of processRow = wantedPID then return contents of processRow
	end repeat
	return missing value
end rowForPID

on isDescendant(processRows, candidateRow)
	set ancestorPID to parentValue of candidateRow
	repeat (count processRows) times
		if ancestorPID = ownerPID then return true
		if ancestorPID ≤ 1 then return false
		set ancestorRow to my rowForPID(processRows, ancestorPID)
		if ancestorRow is missing value then return false
		set ancestorPID to parentValue of ancestorRow
	end repeat
	return false
end isDescendant

on isChooserCommand(commandText)
	if commandText does not start with "/usr/bin/osascript " and commandText does not start with "osascript " then return false
	return commandText contains "on run argv" and commandText contains "POSIX path of (choose folder with prompt \"Choose a Git repository to add to Projects\"" and commandText contains "default location (POSIX file (item 1 of argv))"
end isChooserCommand

on waitForPicker()
	repeat
		my checkDeadline()
		set processRows to my processSnapshot()
		if my rowForPID(processRows, ownerPID) is missing value then error "OwnerPid no longer exists; refusing to touch another process's dialog."
		set matchingPIDs to {}
		repeat with processRow in processRows
			if my isChooserCommand(commandValue of processRow) then
				if my isDescendant(processRows, contents of processRow) then set end of matchingPIDs to pidValue of processRow
			end if
		end repeat
		if (count matchingPIDs) > 1 then error "Multiple descendant CHOOSE_FOLDER processes exist; refusing an ambiguous dialog target."
		if (count matchingPIDs) = 1 then return item 1 of matchingPIDs
		my pauseUntilNextObservation()
	end repeat
end waitForPicker

on assertPickerScope()
	my checkDeadline()
	set processRows to my processSnapshot()
	set pickerRow to my rowForPID(processRows, pickerPID)
	if pickerRow is missing value then error "The scoped native picker exited before its requested action."
	if my rowForPID(processRows, ownerPID) is missing value then error "The GUI owner exited; refusing further UI input."
	if not my isDescendant(processRows, pickerRow) then error "The picker is no longer a descendant of OwnerPid; refusing further UI input."
	if not my isChooserCommand(commandValue of pickerRow) then error "The picker PID no longer has the expected CHOOSE_FOLDER command; refusing further UI input."
end assertPickerScope

on pickerProcess()
	tell application "System Events"
		set candidates to application processes whose unix id is pickerPID
		if (count candidates) = 0 then return missing value
		return item 1 of candidates
	end tell
end pickerProcess

on waitForPanel()
	repeat
		my assertPickerScope()
		set targetProcess to my pickerProcess()
		if targetProcess is not missing value then
			tell application "System Events"
				if (count windows of targetProcess) > 0 then return window 1 of targetProcess
			end tell
		end if
		my pauseUntilNextObservation()
	end repeat
end waitForPanel

on focusPanel(targetPanel)
	my assertPickerScope()
	set targetProcess to my pickerProcess()
	if targetProcess is missing value then error "The scoped picker has no accessible application process."
	tell application "System Events"
		set frontmost of targetProcess to true
		perform action "AXRaise" of targetPanel
	end tell
	repeat
		my assertPickerScope()
		tell application "System Events"
			if frontmost of targetProcess then exit repeat
		end tell
		my pauseUntilNextObservation()
	end repeat
end focusPanel

on scopedKey(targetPanel, keyKind)
	my focusPanel(targetPanel)
	my assertPickerScope()
	set targetProcess to my pickerProcess()
	tell application "System Events"
		if not frontmost of targetProcess then error "Picker lost focus; refusing keyboard input."
		set focusedProcesses to application processes whose frontmost is true
		if (count focusedProcesses) is not 1 then error "Cannot establish exclusive picker focus; refusing keyboard input."
		if unix id of item 1 of focusedProcesses is not pickerPID then error "Another process owns keyboard focus; refusing keyboard input."
		tell targetProcess
			if keyKind = "goToFolder" then
				keystroke "g" using {command down, shift down}
			else if keyKind = "escape" then
				key code 53
			else
				error "Unknown scoped key action."
			end if
		end tell
	end tell
end scopedKey

on axAttribute(targetElement, attributeName)
	try
		tell application "System Events" to return value of attribute attributeName of targetElement
	on error errorMessage number errorNumber
		my raisePermissionError(errorMessage, errorNumber)
		-- Missing attributes and elements are expected while sheets transition.
		if errorNumber is in {-1728, -1719, -25202, -25205, -25212} then return missing value
		error errorMessage number errorNumber
	end try
end axAttribute

on childElements(targetElement)
	try
		tell application "System Events" to return entire contents of targetElement
	on error errorMessage number errorNumber
		my raisePermissionError(errorMessage, errorNumber)
		if errorNumber is in {-1728, -1719, -25202} then return {}
		error errorMessage number errorNumber
	end try
end childElements

on locationEntry(targetPanel)
	set descendants to my childElements(targetPanel)
	-- Prefer an actual text field over its enclosing combo box on older macOS.
	repeat with desiredRole in {"AXTextField", "AXComboBox"}
		repeat with candidateElement in descendants
			if my axAttribute(candidateElement, "AXRole") = (desiredRole as text) then
				if my axAttribute(candidateElement, "AXSubrole") is not "AXSearchField" then
					if my axAttribute(candidateElement, "AXEditable") is not false then return contents of candidateElement
				end if
			end if
		end repeat
	end repeat
	return missing value
end locationEntry

on locationPanel(mainPanel)
	-- Go to Folder is normally an AXSheet; some macOS versions expose a new window.
	repeat with candidateElement in my childElements(mainPanel)
		if my axAttribute(candidateElement, "AXRole") = "AXSheet" then
			if my locationEntry(candidateElement) is not missing value then return contents of candidateElement
		end if
	end repeat
	set targetProcess to my pickerProcess()
	if targetProcess is missing value then return missing value
	tell application "System Events" to set pickerWindows to windows of targetProcess
	repeat with candidateWindow in pickerWindows
		if (contents of candidateWindow) is not mainPanel then
			if my locationEntry(candidateWindow) is not missing value then return contents of candidateWindow
		end if
	end repeat
	return missing value
end locationPanel

on waitForLocationPanel(mainPanel)
	repeat
		my assertPickerScope()
		set foundPanel to my locationPanel(mainPanel)
		if foundPanel is not missing value then return foundPanel
		my pauseUntilNextObservation()
	end repeat
end waitForLocationPanel

on waitForLocationClose(mainPanel)
	repeat
		my assertPickerScope()
		if my locationPanel(mainPanel) is missing value then return
		my pauseUntilNextObservation()
	end repeat
end waitForLocationClose

on waitForDefaultButton(targetPanel, parentPanel)
	repeat
		my assertPickerScope()
		set primaryButton to my axAttribute(targetPanel, "AXDefaultButton")
		-- A sheet's default may be exported on its window, but never press the
		-- underlying picker action before the Go to Folder sheet has closed.
		if primaryButton is missing value and parentPanel is not missing value then
			set windowDefault to my axAttribute(parentPanel, "AXDefaultButton")
			if windowDefault is not missing value then
				if my elementWithin(windowDefault, targetPanel) then set primaryButton to windowDefault
			end if
		end if
		if primaryButton is not missing value then
			if my axAttribute(primaryButton, "AXEnabled") = true then return primaryButton
		end if
		my pauseUntilNextObservation()
	end repeat
end waitForDefaultButton

on elementWithin(candidateElement, targetContainer)
	set ancestorElement to candidateElement
	repeat 64 times
		if ancestorElement is targetContainer then return true
		set ancestorElement to my axAttribute(ancestorElement, "AXParent")
		if ancestorElement is missing value then return false
	end repeat
	return false
end elementWithin

on pressButton(targetButton)
	my assertPickerScope()
	if my axAttribute(targetButton, "AXEnabled") is not true then error "The scoped accessible action is disabled."
	tell application "System Events" to perform action "AXPress" of targetButton
end pressButton

on waitForPickerExit()
	repeat
		my checkDeadline()
		if my rowForPID(my processSnapshot(), pickerPID) is missing value then return
		my pauseUntilNextObservation()
	end repeat
end waitForPickerExit

on raisePermissionError(errorMessage, errorNumber)
	if errorNumber = -1743 then error "Automation permission denied (-1743). Allow the invoking terminal/test host to control System Events in System Settings > Privacy & Security > Automation. " & errorMessage number 1
	if errorNumber = -1712 then error "System Events timed out. A pending Accessibility/Automation permission prompt or an unresponsive GUI may be blocking native picker automation. Grant Accessibility and System Events Automation access to the invoking terminal/test host, then retry. " & errorMessage number 1
	if errorNumber = -25211 or errorMessage contains "assistive access" or errorMessage contains "not allowed to send keystrokes" or errorMessage contains "Accessibility permission" then error "Accessibility permission denied. Allow the invoking terminal/test host in System Settings > Privacy & Security > Accessibility and restart it. " & errorMessage number 1
end raisePermissionError
