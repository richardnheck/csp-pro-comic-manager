<#
.SYNOPSIS
    Builds a PDF, EPUB and/or CBZ from a comic's exported PNG pages.

.DESCRIPTION
    Reads <Folder>\export\images\*.png (as written by csp-export-png.ahk), orders
    them by the number in the file name (Page2 before Page10) and writes
    <Folder>\export\<folder name>.pdf / .epub / .cbz. Needs only Windows PowerShell 5.1 / .NET Framework; nothing to install.

    PDF:  one page per image, embedded losslessly, page size taken from the image's DPI.
    EPUB: fixed-layout EPUB 3 (the usual format for comics), first page used as the cover.
    CBZ:  zip of the pages named 001.png, 002.png, ... plus ComicInfo.xml (title, author),
          for comic readers such as CDisplayEx.

    -Format takes a comma-separated list of pdf, epub and cbz.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build-comic.ps1 -Folder "..\..\examples\comic1"
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build-comic.ps1 -Folder "..\..\examples\comic1" -Format "epub,cbz" -Title "My Comic" -Author "Jane Smith"
#>
param(
    [Parameter(Mandatory)][string]$Folder,
    [string]$Format = 'pdf,epub',
    [string]$Title,
    [string]$Author = '',
    [string]$Language = 'en'
)
$ErrorActionPreference = 'Stop'

$formats = @($Format.ToLower() -split '[,\s]+' | Where-Object { $_ } | Select-Object -Unique)
$bad = @($formats | Where-Object { $_ -notin 'pdf', 'epub', 'cbz' })
if ($bad.Count -or -not $formats.Count) { throw "-Format must list pdf, epub and/or cbz (got '$Format')" }

$Folder = (Resolve-Path $Folder).Path
$name = Split-Path $Folder -Leaf
if (-not $Title) { $Title = $name }
$exportDir = Join-Path $Folder 'export'
$imagesDir = Join-Path $exportDir 'images'
New-Item -ItemType Directory -Force $imagesDir | Out-Null  # creates export\ too if missing

# Natural sort: pad every number in the name so "Page2" sorts before "Page10"
$pages = @(Get-ChildItem $imagesDir -Filter *.png -File -ErrorAction SilentlyContinue |
    Sort-Object { [regex]::Replace($_.BaseName, '\d+', { $args[0].Value.PadLeft(10, '0') }) })
if (-not $pages.Count) { throw "No PNG pages found in $imagesDir" }

Add-Type -ReferencedAssemblies System.Drawing, System.IO.Compression -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security;
using System.Text;

public static class ComicBook
{
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    // ---- PDF ---------------------------------------------------------------

    public static void WritePdf(string[] images, string outPath, string title, string author)
    {
        int n = images.Length;
        // Object ids: 1 catalog, 2 page tree, 3 info, then per page: page, contents, image
        var offsets = new long[4 + n * 3];
        using (var fs = new FileStream(outPath, FileMode.Create, FileAccess.Write))
        {
            Action<string> w = s => { var b = Encoding.ASCII.GetBytes(s); fs.Write(b, 0, b.Length); };
            w("%PDF-1.4\n");
            fs.Write(new byte[] { (byte)'%', 0xE2, 0xE3, 0xCF, 0xD3, (byte)'\n' }, 0, 6);

            var kids = new StringBuilder();
            for (int i = 0; i < n; i++)
            {
                int pageId = 4 + i * 3, contentId = pageId + 1, imageId = pageId + 2;
                kids.Append(pageId).Append(" 0 R ");

                int pw, ph; float dpi;
                byte[] pixels = ZlibRgb(images[i], out pw, out ph, out dpi);
                string wPt = (pw * 72.0 / dpi).ToString("0.###", Inv);
                string hPt = (ph * 72.0 / dpi).ToString("0.###", Inv);

                offsets[imageId] = fs.Position;
                w(imageId + " 0 obj\n<< /Type /XObject /Subtype /Image /Width " + pw + " /Height " + ph +
                  " /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length " + pixels.Length + " >>\nstream\n");
                fs.Write(pixels, 0, pixels.Length);
                w("\nendstream\nendobj\n");

                string draw = "q " + wPt + " 0 0 " + hPt + " 0 0 cm /Im0 Do Q";
                offsets[contentId] = fs.Position;
                w(contentId + " 0 obj\n<< /Length " + draw.Length + " >>\nstream\n" + draw + "\nendstream\nendobj\n");

                offsets[pageId] = fs.Position;
                w(pageId + " 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 " + wPt + " " + hPt + "]" +
                  " /Resources << /XObject << /Im0 " + imageId + " 0 R >> >> /Contents " + contentId + " 0 R >>\nendobj\n");
            }

            offsets[1] = fs.Position;
            w("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
            offsets[2] = fs.Position;
            w("2 0 obj\n<< /Type /Pages /Count " + n + " /Kids [" + kids + "] >>\nendobj\n");
            offsets[3] = fs.Position;
            w("3 0 obj\n<< /Title " + PdfText(title) + (author != "" ? " /Author " + PdfText(author) : "") +
              " /Producer (csp-pro-comic-manager) >>\nendobj\n");

            long xref = fs.Position;
            w("xref\n0 " + offsets.Length + "\n0000000000 65535 f \n");
            for (int id = 1; id < offsets.Length; id++)
                w(offsets[id].ToString("D10") + " 00000 n \n");
            w("trailer\n<< /Size " + offsets.Length + " /Root 1 0 R /Info 3 0 R >>\nstartxref\n" + xref + "\n%%EOF\n");
        }
    }

    // Image as zlib-compressed RGB rows, transparency flattened onto white
    static byte[] ZlibRgb(string path, out int w, out int h, out float dpi)
    {
        using (var src = new Bitmap(path))
        {
            w = src.Width; h = src.Height;
            dpi = src.HorizontalResolution > 1 ? src.HorizontalResolution : 72f;
            using (var rgb = new Bitmap(w, h, PixelFormat.Format24bppRgb))
            {
                using (var g = Graphics.FromImage(rgb))
                {
                    g.Clear(Color.White);
                    g.DrawImage(src, new Rectangle(0, 0, w, h));
                }
                var data = rgb.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
                try
                {
                    var ms = new MemoryStream();
                    ms.WriteByte(0x78); ms.WriteByte(0x9C);  // zlib header
                    uint a = 1, b = 0;                        // Adler-32
                    var row = new byte[w * 3];
                    using (var z = new DeflateStream(ms, CompressionLevel.Optimal, true))
                    {
                        for (int y = 0; y < h; y++)
                        {
                            Marshal.Copy(data.Scan0 + y * data.Stride, row, 0, row.Length);
                            for (int x = 0; x < row.Length; x += 3) { byte t = row[x]; row[x] = row[x + 2]; row[x + 2] = t; }  // BGR -> RGB
                            for (int i = 0; i < row.Length; i++) { a = (a + row[i]) % 65521; b = (b + a) % 65521; }
                            z.Write(row, 0, row.Length);
                        }
                    }
                    uint adler = (b << 16) | a;
                    ms.WriteByte((byte)(adler >> 24)); ms.WriteByte((byte)(adler >> 16));
                    ms.WriteByte((byte)(adler >> 8)); ms.WriteByte((byte)adler);
                    return ms.ToArray();
                }
                finally { rgb.UnlockBits(data); }
            }
        }
    }

    // UTF-16BE hex string, so any title characters survive
    static string PdfText(string s)
    {
        var sb = new StringBuilder("<FEFF");
        foreach (char c in s) sb.Append(((int)c).ToString("X4"));
        return sb.Append(">").ToString();
    }

    // ---- EPUB --------------------------------------------------------------

    public static void WriteEpub(string[] images, string outPath, string title, string author, string language)
    {
        if (File.Exists(outPath)) File.Delete(outPath);
        string t = SecurityElement.Escape(title);
        string id = "urn:uuid:" + Guid.NewGuid();
        string modified = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", Inv);

        // "mimetype" must be the first entry and truly stored (method 0). .NET Framework's ZipArchive
        // can't do that, so write a one-entry zip by hand and add everything else in Update mode.
        WriteMimetypeZip(outPath);
        using (var zip = new ZipArchive(new FileStream(outPath, FileMode.Open), ZipArchiveMode.Update))
        {
            Text(zip, "META-INF/container.xml",
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\">\n" +
                "  <rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles>\n</container>\n");

            var manifest = new StringBuilder();
            var spine = new StringBuilder();
            var nav = new StringBuilder();
            for (int i = 0; i < images.Length; i++)
            {
                int num = i + 1;
                string img = "images/page" + num.ToString("D4") + ".png";
                string page = "page" + num.ToString("D4") + ".xhtml";
                int pw, ph;
                using (var fs = File.OpenRead(images[i]))
                using (var bmp = Image.FromStream(fs, false, false)) { pw = bmp.Width; ph = bmp.Height; }

                using (var src = File.OpenRead(images[i]))
                using (var dst = zip.CreateEntry("OEBPS/" + img, CompressionLevel.NoCompression).Open())  // PNG is already compressed
                    src.CopyTo(dst);
                Text(zip, "OEBPS/" + page,
                    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\">\n<head>\n" +
                    "  <title>" + t + " - Page " + num + "</title>\n" +
                    "  <meta name=\"viewport\" content=\"width=" + pw + ", height=" + ph + "\"/>\n" +
                    // Fit the image to the screen: fixed-layout readers make the screen exactly one page
                    // (the viewport above); readers that ignore the viewport, like Calibre's, still get a whole page
                    "  <style>html, body { margin: 0; padding: 0; width: 100%; height: 100%; } " +
                    "img { display: block; width: 100%; height: 100%; object-fit: contain; }</style>\n" +
                    "</head>\n<body><img src=\"" + img + "\" alt=\"Page " + num + "\"/></body>\n</html>\n");

                manifest.Append("    <item id=\"img" + num + "\" href=\"" + img + "\" media-type=\"image/png\"" + (i == 0 ? " properties=\"cover-image\"" : "") + "/>\n");
                manifest.Append("    <item id=\"p" + num + "\" href=\"" + page + "\" media-type=\"application/xhtml+xml\"/>\n");
                spine.Append("    <itemref idref=\"p" + num + "\"/>\n");
                nav.Append("      <li><a href=\"" + page + "\">Page " + num + "</a></li>\n");
            }

            Text(zip, "OEBPS/nav.xhtml",
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">\n" +
                "<head><title>" + t + "</title></head>\n<body>\n  <nav epub:type=\"toc\">\n    <h1>" + t + "</h1>\n    <ol>\n" + nav +
                "    </ol>\n  </nav>\n</body>\n</html>\n");

            Text(zip, "OEBPS/content.opf",
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
                "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"bookid\" prefix=\"rendition: http://www.idpf.org/vocab/rendition/#\">\n" +
                "  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n" +
                "    <dc:identifier id=\"bookid\">" + id + "</dc:identifier>\n" +
                "    <dc:title>" + t + "</dc:title>\n" +
                (author != "" ? "    <dc:creator>" + SecurityElement.Escape(author) + "</dc:creator>\n" : "") +
                "    <dc:language>" + SecurityElement.Escape(language) + "</dc:language>\n" +
                "    <meta property=\"dcterms:modified\">" + modified + "</meta>\n" +
                "    <meta property=\"rendition:layout\">pre-paginated</meta>\n" +
                "    <meta property=\"rendition:spread\">auto</meta>\n" +
                "    <meta name=\"cover\" content=\"img1\"/>\n" +
                "  </metadata>\n  <manifest>\n" +
                "    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n" + manifest +
                "  </manifest>\n  <spine>\n" + spine + "  </spine>\n</package>\n");
        }
    }

    // ---- CBZ ---------------------------------------------------------------

    public static void WriteCbz(string[] images, string outPath, string title, string author, string language)
    {
        if (File.Exists(outPath)) File.Delete(outPath);
        // Number the pages so every reader sorts them the same way, whatever the original names
        int digits = Math.Max(3, images.Length.ToString().Length);
        using (var zip = new ZipArchive(new FileStream(outPath, FileMode.Create), ZipArchiveMode.Create))
        {
            for (int i = 0; i < images.Length; i++)
            {
                string entry = (i + 1).ToString("D" + digits) + Path.GetExtension(images[i]).ToLowerInvariant();
                using (var src = File.OpenRead(images[i]))
                using (var dst = zip.CreateEntry(entry, CompressionLevel.NoCompression).Open())  // PNG is already compressed
                    src.CopyTo(dst);
            }
            Text(zip, "ComicInfo.xml",
                "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
                "<ComicInfo xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n" +
                "  <Title>" + SecurityElement.Escape(title) + "</Title>\n" +
                (author != "" ? "  <Writer>" + SecurityElement.Escape(author) + "</Writer>\n" : "") +
                "  <PageCount>" + images.Length + "</PageCount>\n" +
                "  <LanguageISO>" + SecurityElement.Escape(language) + "</LanguageISO>\n" +
                "</ComicInfo>\n");
        }
    }

    static void WriteMimetypeZip(string path)
    {
        byte[] name = Encoding.ASCII.GetBytes("mimetype");
        byte[] data = Encoding.ASCII.GetBytes("application/epub+zip");
        const uint crc = 0x2CAB616F;  // CRC-32 of "application/epub+zip"
        using (var bw = new BinaryWriter(new FileStream(path, FileMode.Create)))
        {
            // Local file header
            bw.Write(0x04034b50u); bw.Write((ushort)10); bw.Write((ushort)0); bw.Write((ushort)0);
            bw.Write((ushort)0); bw.Write((ushort)0x21);  // time/date
            bw.Write(crc); bw.Write((uint)data.Length); bw.Write((uint)data.Length);
            bw.Write((ushort)name.Length); bw.Write((ushort)0);
            bw.Write(name); bw.Write(data);
            long cdStart = bw.BaseStream.Position;
            // Central directory header
            bw.Write(0x02014b50u); bw.Write((ushort)10); bw.Write((ushort)10); bw.Write((ushort)0); bw.Write((ushort)0);
            bw.Write((ushort)0); bw.Write((ushort)0x21);
            bw.Write(crc); bw.Write((uint)data.Length); bw.Write((uint)data.Length);
            bw.Write((ushort)name.Length); bw.Write((ushort)0); bw.Write((ushort)0);
            bw.Write((ushort)0); bw.Write((ushort)0); bw.Write(0u); bw.Write(0u);
            bw.Write(name);
            long cdEnd = bw.BaseStream.Position;
            // End of central directory
            bw.Write(0x06054b50u); bw.Write((ushort)0); bw.Write((ushort)0); bw.Write((ushort)1); bw.Write((ushort)1);
            bw.Write((uint)(cdEnd - cdStart)); bw.Write((uint)cdStart); bw.Write((ushort)0);
        }
    }

    static void Text(ZipArchive zip, string name, string content, CompressionLevel level = CompressionLevel.Optimal)
    {
        using (var s = zip.CreateEntry(name, level).Open())
        {
            var b = new UTF8Encoding(false).GetBytes(content);
            s.Write(b, 0, b.Length);
        }
    }
}
'@

$paths = [string[]]($pages.FullName)
"Pages ($($paths.Count)): " + (($pages.Name) -join ', ')

if ('pdf' -in $formats) {
    $pdf = Join-Path $exportDir "$name.pdf"
    [ComicBook]::WritePdf($paths, $pdf, $Title, $Author)
    "Wrote $pdf ({0:N1} MB)" -f ((Get-Item $pdf).Length / 1MB)
}
if ('epub' -in $formats) {
    $epub = Join-Path $exportDir "$name.epub"
    [ComicBook]::WriteEpub($paths, $epub, $Title, $Author, $Language)
    "Wrote $epub ({0:N1} MB)" -f ((Get-Item $epub).Length / 1MB)
}
if ('cbz' -in $formats) {
    $cbz = Join-Path $exportDir "$name.cbz"
    [ComicBook]::WriteCbz($paths, $cbz, $Title, $Author, $Language)
    "Wrote $cbz ({0:N1} MB)" -f ((Get-Item $cbz).Length / 1MB)
}
