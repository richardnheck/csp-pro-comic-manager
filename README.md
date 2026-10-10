# CSP Pro Comic Manager

Turn a folder of Clip Studio Paint pages (`.clip` files) into a finished comic: PNG page images, plus a **PDF**, **EPUB** and/or **CBZ** you can read or share.

Clip Studio has no command line, so the export step uses [AutoHotkey](https://www.autohotkey.com/) to drive Clip Studio for you: it opens each page, exports it to PNG and closes it. The book is then built from those images with Windows PowerShell, with nothing else to install.

## Requirements

- Windows 10 or 11
- [Clip Studio Paint](https://www.clipstudio.net/) (PRO or EX)
- [AutoHotkey v2](https://www.autohotkey.com/)
- Windows PowerShell 5.1 (included with Windows)

## One-time setup in Clip Studio

1. **Assign the export shortcut.** In **File → Shortcut Settings**, choose **Main menu → File → Export (Single Layer) → .png** and assign **Ctrl+Alt+Shift+P**. Clip Studio has no shortcut for this by default.
   To use a different shortcut, also change `CSP_EXPORT_KEY` in `scripts/core/csp-export-png.ahk`.
2. **Check File → Open and File → Close** still use Ctrl+O and Ctrl+W (the defaults).
3. **Export one page by hand** with File → Export (Single Layer) → .png and set the export options you want. The scripts accept whatever settings Clip Studio last used. In particular:
   - **Expression color** – choose *RGB color* if your pages are in colour. Pages created from some comic templates default to greyscale.
   - **Preview rendering result** – untick it to skip the preview window on every page.

"Export (Single Layer)" exports the **whole page**: every visible layer merged into one image. Hidden layers are left out, as are draft layers unless the export settings include them.

## Using the app

Start Clip Studio, then double-click **`scripts/build-comic-app.ahk`** to open the **Build CSP Comic** window.

| Section | Setting | What it does |
|---|---|---|
| Comic | **Title**, **Author** | Stored in the book's metadata. Saved per comic in `comic.ini`. The title defaults to the folder name. |
| Comic | **Folder** | The folder containing the comic's `.clip` pages. |
| Export | **Pages** | *All pages*, or a single `.clip` file. Use a single page when you've only edited that one. |
| Export | **Delete existing images first** | Available with *All pages*. Clears old PNGs, for example after removing or renaming a page. Never remembered between sessions. |
| Build | **Formats** | Any combination of PDF, EPUB and CBZ. |

Then click one of:

- **Export Images** – export the chosen page(s) to PNG only.
- **Export Images and Build** – export, then build the ticked formats. Pressing Enter runs this one.
- **Build Only** – build from the images already exported. Clip Studio isn't needed.

When an export starts, Clip Studio asks you to confirm. Click **OK**, then **don't touch the keyboard or mouse** until it finishes, because the script is typing into Clip Studio. Press **Esc** to stop after the current page.

The book always uses every PNG in `export/images`, so after re-exporting one page the others are reused unchanged.

## What gets created

```
my-comic/
  Page 001.clip, Page 002.clip, ...
  comic.ini              title and author for this comic
  export/
    images/              one PNG per page
    my-comic.pdf
    my-comic.epub
    my-comic.cbz
```

Pages are ordered by the number in the file name, so `Page 2` comes before `Page 10`.

| Format | Details |
|---|---|
| **PDF** | One page per image, embedded without quality loss. Page size comes from the image resolution (e.g. an A4 page at 600 dpi stays A4). |
| **EPUB** | Fixed-layout EPUB 3, one page per screen. The first page is the cover. Works in Apple Books, Kobo, Calibre and similar readers. |
| **CBZ** | Pages named `001.png`, `002.png`, ... with a `ComicInfo.xml` holding the title and author. For comic readers such as CDisplayEx. |

## Running the scripts directly

Both scripts in `scripts/core` work without the app.

**Export pages to PNG** (Clip Studio must be running):

```
AutoHotkey64.exe scripts\core\csp-export-png.ahk "C:\Comics\my-comic"
AutoHotkey64.exe scripts\core\csp-export-png.ahk "C:\Comics\my-comic\Page 003.clip"
AutoHotkey64.exe scripts\core\csp-export-png.ahk "C:\Comics\my-comic" /clean
```

`/clean` deletes the existing PNGs first and only works with a folder. Exit codes: `0` all pages exported, `1` failed, `2` cancelled.

**Build the books:**

```
powershell -ExecutionPolicy Bypass -File scripts\core\build-comic.ps1 -Folder "C:\Comics\my-comic" -Format "pdf,epub,cbz" -Title "My Comic" -Author "Jane Smith"
```

`-Format` is a comma-separated list of `pdf`, `epub` and `cbz` (default `pdf,epub`). `-Title` defaults to the folder name, and `-Author` is optional.

## Troubleshooting

- **Something went wrong during an export.** Each run is recorded in `logs/csp-export.log` with the reason for any failure.
- **"Couldn't bring Clip Studio to the front"** – Windows blocked the switch. Start the export from the app or the script so you click the confirmation, and don't switch windows while it runs.
- **"Export dialog didn't open"** – check the shortcut from the setup steps. If large pages are still loading when the export starts, increase `LOAD_DELAY` in `scripts/core/csp-export-png.ahk`.
- **The images don't land in `export/images`** – the save dialog didn't accept the typed path. Leave the keyboard and mouse alone during the export and try again.
- **A colour element is missing or grey** – set Expression color to RGB in the export settings (see setup step 3).
- **Can't delete or rename a comic folder** – Clip Studio may still have it open from its last export. Use File → Open in Clip Studio, browse to another folder and cancel, or close Clip Studio.

## Project layout

```
scripts/
  build-comic-app.ahk     the app
  core/
    csp-export-png.ahk    exports .clip pages to PNG through Clip Studio
    build-comic.ps1       builds PDF / EPUB / CBZ from the PNGs
examples/comic1/          sample comic
logs/                     export logs (not committed)
```
