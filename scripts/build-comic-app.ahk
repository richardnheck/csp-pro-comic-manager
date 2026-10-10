#Requires AutoHotkey v2.0
#SingleInstance Force

; Window for publishing a comic. Pick the folder of .clip pages, then:
;   Export Images            - export the chosen page(s) to export\images\*.png with Clip Studio
;   Export Images and Build  - the same, then build the PDF, EPUB and/or CBZ into export\
;   Build Only               - build the PDF, EPUB and/or CBZ from the images already exported
; Runs core\csp-export-png.ahk (pages -> export\images\*.png) and core\build-comic.ps1 (-> export\).
; The book is always built from every PNG in export\images, so after re-exporting one page the
; other pages are reused as they are.
; Clip Studio Paint must already be running for the two Export buttons.

EXPORT_SCRIPT := A_ScriptDir "\core\csp-export-png.ahk"
LAST_RESULT   := A_ScriptDir "\..\logs\csp-export-last.txt"
BUILD_SCRIPT  := A_ScriptDir "\core\build-comic.ps1"
SETTINGS      := A_ScriptDir "\build-comic-app.ini"  ; remembers the last folder and formats
ALL_PAGES     := "All pages"

g := Gui(, "Build CSP Comic")
g.SetFont("s10")

Heading("Comic")
g.AddText("xm", "Title:")
titleEdit := g.AddEdit("xm w508")
g.AddText("xm", "Author:")
authorEdit := g.AddEdit("xm w508")
g.AddText("xm", "Folder (contains the .clip pages):")
folderEdit := g.AddEdit("xm w420 r1", IniRead(SETTINGS, "last", "folder", ""))
folderEdit.OnEvent("Change", (*) => LoadFolder())
g.AddButton("x+8 yp-1 w80", "Browse...").OnEvent("Click", Browse)

Heading("Export")
g.AddText("xm", "Pages:")
pageList := g.AddDropDownList("x+8 yp-3 w260")
pageList.OnEvent("Change", (*) => UpdateCleanBox())
; Not remembered between sessions, so images are never deleted by accident
cleanBox := g.AddCheckbox("xm", "Delete existing images first")

Heading("Build")
g.AddText("xm", "Formats:")
pdfBox  := g.AddCheckbox("x+8 yp Checked" IniRead(SETTINGS, "last", "pdf", 1), "PDF")
epubBox := g.AddCheckbox("x+20 yp Checked" IniRead(SETTINGS, "last", "epub", 1), "EPUB")
cbzBox  := g.AddCheckbox("x+20 yp Checked" IniRead(SETTINGS, "last", "cbz", 1), "CBZ (comic readers)")

exportBtn := g.AddButton("xm y+18 w130", "Export Images")
exportBtn.OnEvent("Click", (*) => StartJob("export"))
exportBuildBtn := g.AddButton("x+8 yp w200 Default", "Export Images and Build")
exportBuildBtn.OnEvent("Click", (*) => StartJob("exportAndBuild"))
buildBtn := g.AddButton("x+8 yp w110", "Build Only")
buildBtn.OnEvent("Click", (*) => StartJob("build"))
status := g.AddEdit("xm w508 r8 ReadOnly")
openBtn := g.AddButton("xm w160 Disabled", "Open export folder")
openBtn.OnEvent("Click", (*) => Run('"' GetFolder() '\export"'))
g.OnEvent("Close", (*) => ExitApp())
LoadFolder()
g.Show()

Heading(text) {
    g.SetFont("s10 bold")
    g.AddText("xm y+14", text)
    g.SetFont("s10 norm")
}

GetFolder() => RTrim(Trim(folderEdit.Value, " `t`""), "\")

; Deleting every image only makes sense when every page is about to be exported again
UpdateCleanBox() {
    allPages := (pageList.Text = ALL_PAGES)
    cleanBox.Enabled := allPages
    if !allPages
        cleanBox.Value := 0
}

; Fills in the title, author and page list for the folder in the box
LoadFolder() {
    pageList.Delete()
    pageList.Add([ALL_PAGES])
    pageList.Choose(1)
    UpdateCleanBox()
    folder := GetFolder()
    if (folder = "" || !InStr(FileExist(folder), "D"))
        return

    ; Each comic's title and author are saved in <comic folder>\comic.ini; the title defaults to the folder name
    SplitPath(folder, &name)
    titleEdit.Value := IniRead(folder "\comic.ini", "comic", "title", name)
    authorEdit.Value := IniRead(folder "\comic.ini", "comic", "author", "")

    ; Page files in number order, so Page2 comes before Page10
    lines := ""
    Loop Files folder "\*.clip"
        lines .= PadNumbers(A_LoopFileName) "`t" A_LoopFileName "`n"
    pages := []
    for line in StrSplit(Sort(RTrim(lines, "`n")), "`n")
        if (line != "")
            pages.Push(StrSplit(line, "`t")[2])
    pageList.Add(pages)
}

PadNumbers(s) {
    out := "", pos := 1
    while RegExMatch(s, "\d+", &m, pos) {
        out .= SubStr(s, pos, m.Pos - pos) Format("{:010}", m[0])
        pos := m.Pos + m.Len
    }
    return out SubStr(s, pos)
}

Browse(*) {
    sel := DirSelect("*" GetFolder(), 0, "Choose the comic folder")
    if (sel != "") {
        folderEdit.Value := sel
        LoadFolder()
    }
}

; mode: "export" (images only), "exportAndBuild" (images then book) or "build" (book from existing images)
StartJob(mode) {
    folder := GetFolder()
    if (folder = "" || !InStr(FileExist(folder), "D")) {
        MsgBox("Folder not found:`n" folder, "Publish Comic", "Icon!")
        return
    }
    ; Ticked formats, e.g. ["pdf", "cbz"]
    formats := []
    for pair in [[pdfBox, "pdf"], [epubBox, "epub"], [cbzBox, "cbz"]]
        if pair[1].Value
            formats.Push(pair[2])
    if (mode != "export" && !formats.Length) {
        MsgBox("Tick at least one format (PDF, EPUB or CBZ) under Build.", "Publish Comic", "Icon!")
        return
    }
    page := (pageList.Text = ALL_PAGES) ? "" : pageList.Text
    ; Double quotes would break the command line, so swap them for single quotes
    title := StrReplace(Trim(titleEdit.Value), '"', "'")
    if (title = "")
        SplitPath(folder, &title)
    titleEdit.Value := title
    author := StrReplace(Trim(authorEdit.Value), '"', "'")
    authorEdit.Value := author
    IniWrite(folder, SETTINGS, "last", "folder")
    IniWrite(pdfBox.Value, SETTINGS, "last", "pdf")
    IniWrite(epubBox.Value, SETTINGS, "last", "epub")
    IniWrite(cbzBox.Value, SETTINGS, "last", "cbz")
    try IniDelete(SETTINGS, "last", "imagesonly")  ; left over from the old "Images only" checkbox
    IniWrite(title, folder "\comic.ini", "comic", "title")
    IniWrite(author, folder "\comic.ini", "comic", "author")
    ; Book details as build-comic.ps1 options. An empty -Author "" can be dropped by
    ; Windows PowerShell and break the call, so it's only added when there is one.
    bookArgs := ' -Title "' title '"' (author != "" ? ' -Author "' author '"' : "")

    SetButtons(false)
    openBtn.Enabled := false
    try {
        if (mode = "build") {
            Log("Using the existing images in " folder "\export\images", true)
            BuildBook(folder, formats, bookArgs)
        } else if ExportImages(folder, page, mode = "exportAndBuild") {
            if (mode = "exportAndBuild")
                BuildBook(folder, formats, bookArgs)
            else {
                Log("Done. Images are in " folder "\export\images")
                openBtn.Enabled := true
            }
        }
    } finally {
        SetButtons(true)
    }
}

SetButtons(enabled) {
    exportBtn.Enabled := enabled
    exportBuildBtn.Enabled := enabled
    buildBtn.Enabled := enabled
}

; Returns true if every page exported
ExportImages(folder, page, thenBuild) {
    Log("Exporting " (page = "" ? "all pages" : page) " from Clip Studio...", true)
    try FileDelete(LAST_RESULT)
    target := (page = "") ? folder : folder "\" page
    ; /clean: the export script deletes export\images\*.png after you confirm its start pop-up
    clean := (page = "" && cleanBox.Value) ? " /clean" : ""
    code := RunWait('"' A_AhkPath '" "' EXPORT_SCRIPT '" "' target '"' clean)
    if FileExist(LAST_RESULT)
        Log(Trim(FileRead(LAST_RESULT, "UTF-8"), "`r`n"))
    if (code = 2) {
        Log("Cancelled.")
        return false
    }
    if (code != 0) {
        Log("Export failed" (thenBuild ? ", so the book wasn't built." : ".") " See logs\csp-export.log")
        return false
    }
    return true
}

BuildBook(folder, formats, bookArgs) {
    ; "pdf,cbz" for the build script; "PDF and CBZ" for the status box
    fmt := "", names := ""
    for i, f in formats {
        fmt .= (i > 1 ? "," : "") f
        names .= (i = 1 ? "" : i = formats.Length ? " and " : ", ") StrUpper(f)
    }
    Log("Building " names "...")
    out := A_Temp "\build-comic-app-output.txt"
    code := RunWait(A_ComSpec ' /c ""powershell" -NoProfile -ExecutionPolicy Bypass -File "' BUILD_SCRIPT
        . '" -Folder "' folder '" -Format "' fmt '"' bookArgs ' > "' out '" 2>&1"', , "Hide")
    if FileExist(out) {
        Log(Trim(FileRead(out), "`r`n"))
        FileDelete(out)
    }
    if (code != 0)
        return Log("Building failed.")
    Log("Done. Files are in " folder "\export")
    openBtn.Enabled := true
}

Log(text, clear := false) {
    status.Value := (clear ? "" : status.Value) text "`r`n"
    SendMessage(0x115, 7, 0, status)  ; WM_VSCROLL, SB_BOTTOM: keep the latest line visible
}
