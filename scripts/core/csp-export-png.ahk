#Requires AutoHotkey v2.0
#SingleInstance Force

; Exports .clip files to PNG using Clip Studio Paint.
; Each file is opened in CSP, exported to <clip folder>\export\images\<name>.png, then closed.
;
; Usage:
;   AutoHotkey64.exe csp-export-png.ahk "C:\path\to\comic1"        (every .clip in the folder)
;   AutoHotkey64.exe csp-export-png.ahk "C:\path\to\comic1\Page1.clip"
;   AutoHotkey64.exe csp-export-png.ahk "C:\path\to\comic1" /clean (delete export\images\*.png first)
;   Double-click the script to pick a folder.
; Press Esc to stop after the current file.
;
; Setup (once, in Clip Studio):
;   File > Shortcut Settings > Main menu > File > Export (Single Layer) > .png
;   assign the shortcut below (default Ctrl+Alt+Shift+P).
; Clip Studio must already be running.

; ---- Settings ---------------------------------------------------------------
EXPORT_SUBDIR  := "export\images"
; (Ctrl + Alt + Shift + P) CSP shortcut for File > Export (Single Layer) > .png.
; CSP has no shortcut for this by default, so assign this one in CSP (see Setup above).
; If you choose a different one, change it here too: ^ = Ctrl, ! = Alt, + = Shift.
CSP_EXPORT_KEY := "^!+p"
CSP_OPEN_KEY   := "^o"     ; (Ctrl + O) CSP shortcut for File > Open
CSP_CLOSE_KEY  := "^w"     ; (Ctrl + W) CSP shortcut for File > Close
LOAD_DELAY     := 2000     ; ms to let a file finish loading after the Open dialog closes
DIALOG_TIMEOUT := 10       ; seconds to wait for each dialog
EXPORT_TIMEOUT := 60       ; seconds to wait for the PNG to appear on disk
LOG_DIR        := A_ScriptDir "\..\..\logs"  ; <project root>\logs (git-ignored)
; -----------------------------------------------------------------------------

global stopRequested := false
Esc:: {
    global stopRequested := true
}

target := A_Args.Length ? A_Args[1] : DirSelect(, 0, "Folder of .clip files to export")
if (target = "")
    ExitApp
clean := A_Args.Length >= 2 && A_Args[2] = "/clean"

clips := []
isFolder := InStr(FileExist(target), "D")
if isFolder {
    Loop Files, target "\*.clip"
        clips.Push(A_LoopFileFullPath)
} else if FileExist(target) {
    clips.Push(target)
}
if (clean && !isFolder) {
    MsgBox("/clean only works when exporting a whole folder.", "CSP Export", "Icon!")
    ExitApp(1)
}
if !clips.Length {
    MsgBox("No .clip files found at:`n" target, "CSP Export", "Icon!")
    ExitApp(1)
}

cspHwnd := WinExist("CLIP STUDIO PAINT ahk_exe CLIPStudioPaint.exe")
if !cspHwnd {
    MsgBox("Clip Studio Paint isn't running. Start it and try again.", "CSP Export", "Icon!")
    ExitApp(1)
}

imagesDir := isFolder ? target "\" EXPORT_SUBDIR : ""
oldImages := 0
if clean
    Loop Files, imagesDir "\*.png"
        oldImages++

; Clicking OK gives this script permission from Windows to bring CSP to the front
if MsgBox("Export " clips.Length " file(s) with Clip Studio?"
    . (oldImages ? "`n`nThe " oldImages " existing image(s) in export\images will be deleted first." : "")
    . "`n`nDon't use the keyboard or mouse until it finishes.", "CSP Export", "OKCancel " (oldImages ? "Icon!" : "Iconi")) != "OK"
    ExitApp(2)  ; cancelled

; Only delete once the user has confirmed
if oldImages {
    try FileDelete(imagesDir "\*.png")
    catch as e {
        MsgBox("Couldn't delete the existing images:`n" e.Message, "CSP Export", "Icon!")
        ExitApp(1)
    }
}


failed := []
done := 0
for clipPath in clips {
    if stopRequested
        break
    try {
        ExportClip(cspHwnd, clipPath)
        done++
    } catch as e {
        failed.Push(clipPath ": " e.Message)
        break  ; don't keep sending keys when something is off
    }
}

msg := (oldImages ? "Deleted " oldImages " existing image(s). " : "") "Exported " done " of " clips.Length " file(s)."
if failed.Length {
    for f in failed
        msg .= "`n" f
}
if stopRequested
    msg .= "`nStopped with Esc."
; No pop-up at the end: the result goes to logs\csp-export.log, and logs\csp-export-last.txt holds
; just this run's result for callers such as build-comic-app.ahk
try DirCreate(LOG_DIR)
try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " msg "`n", LOG_DIR "\csp-export.log", "UTF-8")
try {
    last := FileOpen(LOG_DIR "\csp-export-last.txt", "w", "UTF-8-RAW")
    last.Write(msg "`r`n")
    last.Close()
}
ExitApp((failed.Length || stopRequested) ? 1 : 0)

ExportClip(cspHwnd, clipPath) {
    cspPid := WinGetPID(cspHwnd)
    dlg := "ahk_class #32770 ahk_pid " cspPid

    SplitPath(clipPath, , &clipDir, , &baseName)
    exportDir := clipDir "\" EXPORT_SUBDIR
    DirCreate(exportDir)
    pngPath := exportDir "\" baseName ".png"
    ; Remove any old export so there's no overwrite prompt and we can detect the new file
    if FileExist(pngPath)
        FileDelete(pngPath)

    ; 1. Open the file
    SendToCsp(cspHwnd, CSP_OPEN_KEY)
    FillFileDialog(dlg, clipPath, "Open")
    Sleep(LOAD_DELAY)

    ; 2. Export to PNG
    SendToCsp(cspHwnd, CSP_EXPORT_KEY)
    FillFileDialog(dlg, pngPath, "Export")

    ; 3. Wait for the PNG, accepting CSP's "Export settings" and preview windows as they appear
    deadline := A_TickCount + EXPORT_TIMEOUT * 1000
    while !FileExist(pngPath) {
        if (A_TickCount > deadline)
            throw Error("PNG wasn't created")
        Sleep(1000)
        if !FileExist(pngPath) && WinActive("ahk_pid " cspPid) && WinGetID("A") != cspHwnd
            Send("{Enter}")
    }
    Sleep(500)
    SendToCsp(cspHwnd, CSP_CLOSE_KEY)
    Sleep(1000)
}

; Brings CSP to the front and sends keys, refusing if another window has focus
SendToCsp(cspHwnd, keys) {
    WinActivate(cspHwnd)
    if !WinWaitActive(cspHwnd, , 3)
        throw Error("Couldn't bring Clip Studio to the front (active window: " WinGetTitle("A") ")")
    Sleep(200)
    Send(keys)
}

; Waits for a Windows file dialog, types the path into it and confirms
FillFileDialog(dlg, path, what) {
    if !WinWaitActive(dlg, , DIALOG_TIMEOUT)
        throw Error(what " dialog didn't open")
    hwnd := WinGetID("A")
    Sleep(300)
    ; Type into the file name box like a person would; setting the text directly
    ; isn't always picked up by the dialog. While CSP is still busy the keystrokes
    ; arrive slowly, so wait for the whole path to appear and retype once if it doesn't.
    Loop 2 {
        Send("!n")  ; Alt+N jumps to the "File name" box in Windows file dialogs
        Sleep(200)
        Send("^a{Delete}")
        SendText(path)
        deadline := A_TickCount + 5000
        while (A_TickCount < deadline) {
            Sleep(100)
            box := ControlGetFocus(hwnd)
            text := box ? ControlGetText(box, hwnd) : ""
            if (text = path)
                break 2
        }
    }
    if (text != path)
        throw Error(what " dialog: file name box didn't take the path"
            . " (focused: " (box ? ControlGetClassNN(box) : "none") ", text: '" text "')")
    Send("{Enter}")
    if !WinWaitClose(hwnd, , DIALOG_TIMEOUT)
        throw Error(what " dialog didn't close")
}
