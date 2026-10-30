using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Text.RegularExpressions;

[assembly: AssemblyVersion("1.0.0.0")]

// Integrazione con Esplora risorse per i file .apk, registrata per utente (HKCU) da Register-Association.ps1:
//  ApkThumbnailProvider: anteprima con l'icona dell'app nelle viste a icone medie e grandi (gira in dllhost).
//  ApkIconHandler: la stessa icona nelle viste piccole (Dettagli, Elenco). Gira dentro explorer.exe, quindi
//  tutto è in try/catch, ricade su apk.ico (accanto alla DLL) e non apre mai file di rete.
namespace ApkShell
{
    public enum WTS_ALPHATYPE { WTSAT_UNKNOWN = 0, WTSAT_RGB = 1, WTSAT_ARGB = 2 }

    [ComImport, Guid("e357fccd-a995-4576-b01f-234630154e96"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IThumbnailProvider
    {
        [PreserveSig] int GetThumbnail(uint cx, out IntPtr phbmp, out WTS_ALPHATYPE pdwAlpha);
    }

    [ComImport, Guid("b824b49d-22ac-4161-ac8a-9916e8fa3f7f"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IInitializeWithStream
    {
        void Initialize(IStream pstream, uint grfMode);
    }

    [ComImport, Guid("000214fa-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IExtractIconW
    {
        // szIconFile è il buffer del chiamante: lo scrivo a mano (WriteBuffer) perché uno StringBuilder
        // non viene copiato indietro in modo affidabile quando la chiamata arriva da codice nativo.
        [PreserveSig]
        int GetIconLocation(uint uFlags, IntPtr szIconFile, uint cchMax, out int piIndex, out uint pwFlags);
        [PreserveSig]
        int Extract([MarshalAs(UnmanagedType.LPWStr)] string pszFile, uint nIconIndex, out IntPtr phiconLarge, out IntPtr phiconSmall, uint nIconSize);
    }

    static class Native
    {
        public const int S_OK = 0, S_FALSE = 1, E_FAIL = unchecked((int)0x80004005);
        public const uint GIL_PERINSTANCE = 0x2, GIL_PERCLASS = 0x4, GIL_NOTFILENAME = 0x8, GIL_DONTCACHE = 0x10;

        public static string DllDirectory()
        {
            try { return Path.GetDirectoryName(new Uri(Assembly.GetExecutingAssembly().CodeBase).LocalPath); }
            catch { return null; }
        }

        // Diagnostica: se accanto alla DLL c'è un file debug.flag, scrive delle righe in shell.log.
        public static void Log(string message)
        {
            try
            {
                string dir = DllDirectory();
                if (dir == null || !File.Exists(Path.Combine(dir, "debug.flag"))) return;
                File.AppendAllText(Path.Combine(dir, "shell.log"),
                    DateTime.Now.ToString("HH:mm:ss.fff") + " [" + System.Diagnostics.Process.GetCurrentProcess().ProcessName + "] " + message + Environment.NewLine);
            }
            catch { }
        }

        // copia s più il NUL finale in un buffer nativo di cch caratteri; false se non ci sta
        public static bool WriteBuffer(IntPtr buffer, uint cch, string s)
        {
            if (buffer == IntPtr.Zero || s == null || s.Length + 1 > cch) return false;
            char[] chars = (s + "\0").ToCharArray();
            Marshal.Copy(chars, 0, buffer, chars.Length);
            return true;
        }

        public static Bitmap Fit(Bitmap src, int size)
        {
            double k = Math.Min((double)size / src.Width, (double)size / src.Height);
            int w = Math.Max(1, (int)Math.Round(src.Width * k));
            int h = Math.Max(1, (int)Math.Round(src.Height * k));
            var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bmp))
            {
                g.Clear(Color.Transparent);
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.SmoothingMode = SmoothingMode.HighQuality;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.DrawImage(src, (size - w) / 2, (size - h) / 2, w, h);
            }
            return bmp;
        }
    }

    // ---------------------------------------------------------------- anteprime (icone grandi)

    [ComVisible(true), Guid("7B3F2A6E-5C1D-4E8B-9A44-0D6C1F2E8A91"), ClassInterface(ClassInterfaceType.None)]
    public class ApkThumbnailProvider : IInitializeWithStream, IThumbnailProvider
    {
        IStream stream;

        public void Initialize(IStream pstream, uint grfMode) { stream = pstream; }

        public int GetThumbnail(uint cx, out IntPtr phbmp, out WTS_ALPHATYPE pdwAlpha)
        {
            phbmp = IntPtr.Zero;
            pdwAlpha = WTS_ALPHATYPE.WTSAT_ARGB;
            try
            {
                using (var cs = new ComStream(stream))
                using (var zip = new ZipArchive(cs, ZipArchiveMode.Read))
                {
                    Bitmap icon = ApkIcon.Extract(zip);
                    if (icon == null) return Native.E_FAIL;
                    using (icon)
                    using (Bitmap thumb = Native.Fit(icon, (int)Math.Max(16, cx)))
                    {
                        phbmp = thumb.GetHbitmap(Color.FromArgb(0, 0, 0, 0));
                    }
                    return Native.S_OK;
                }
            }
            catch { return Native.E_FAIL; }
        }
    }

    // ---------------------------------------------------------------- icone (viste piccole)

    [ComVisible(true), Guid("2D9E6B14-8F3A-4C75-A1B0-5E7C93D4F206"), ClassInterface(ClassInterfaceType.None)]
    public class ApkIconHandler : IPersistFile, IExtractIconW
    {
        string path;
        Bitmap icon;
        bool probed;

        // IPersistFile: Explorer ci dice per quale file vuole l'icona
        public void GetClassID(out Guid pClassID) { pClassID = typeof(ApkIconHandler).GUID; }
        public int IsDirty() { return Native.S_FALSE; }
        public void Load(string pszFileName, int dwMode) { path = pszFileName; Native.Log("Load " + pszFileName); }
        public void Save(string pszFileName, bool fRemember) { }
        public void SaveCompleted(string pszFileName) { }
        public void GetCurFile(out string ppszFileName) { ppszFileName = path; }

        void Probe()
        {
            if (probed) return;
            probed = true;
            try
            {
                if (string.IsNullOrEmpty(path)) return;
                string root = Path.GetPathRoot(path);
                if (string.IsNullOrEmpty(root) || root.StartsWith(@"\\", StringComparison.Ordinal)) return;     // mai file di rete
                if (new DriveInfo(root).DriveType != DriveType.Fixed) return;                                   // né unità rimovibili o ottiche
                var fi = new FileInfo(path);
                if (!fi.Exists || fi.Length > 3L * 1024 * 1024 * 1024) return;
                using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var zip = new ZipArchive(fs, ZipArchiveMode.Read))
                {
                    icon = ApkIcon.Extract(zip);
                }
                Native.Log("Probe " + path + " -> " + (icon == null ? "no icon" : icon.Width + "x" + icon.Height));
            }
            catch (Exception ex) { icon = null; Native.Log("Probe failed: " + ex); }
        }

        public int GetIconLocation(uint uFlags, IntPtr szIconFile, uint cchMax, out int piIndex, out uint pwFlags)
        {
            piIndex = 0;
            pwFlags = 0;
            try
            {
                Native.Log("GetIconLocation flags=0x" + uFlags.ToString("X") + " cch=" + cchMax + " path=" + path);
                Probe();
                // L'icona la crea Extract(). Come nome do il percorso dell'APK (mai "*": vorrebbe dire indice
                // nella lista icone di sistema); GIL_NOTFILENAME dice che non è un file da cui leggerla.
                if (icon != null && Native.WriteBuffer(szIconFile, cchMax, path))
                {
                    piIndex = 0;
                    pwFlags = Native.GIL_NOTFILENAME | Native.GIL_PERINSTANCE;
                    Native.Log("GetIconLocation -> S_OK (made by Extract)");
                    return Native.S_OK;
                }
                // nessuna icona nell'APK: indico apk.ico, che sta accanto a questa DLL
                string dir = Native.DllDirectory();
                string ico = dir == null ? null : Path.Combine(dir, "apk.ico");
                if (ico != null && File.Exists(ico) && Native.WriteBuffer(szIconFile, cchMax, ico))
                {
                    pwFlags = Native.GIL_PERCLASS;
                    Native.Log("GetIconLocation -> S_OK " + ico);
                    return Native.S_OK;
                }
            }
            catch (Exception ex) { Native.Log("GetIconLocation failed: " + ex); }
            Native.Log("GetIconLocation -> S_FALSE");
            return Native.S_FALSE;
        }

        public int Extract(string pszFile, uint nIconIndex, out IntPtr phiconLarge, out IntPtr phiconSmall, uint nIconSize)
        {
            phiconLarge = IntPtr.Zero;
            phiconSmall = IntPtr.Zero;
            try
            {
                Probe();
                if (icon == null) return Native.S_FALSE;        // Explorer la estrae dal file indicato da GetIconLocation
                int large = (int)(nIconSize & 0xFFFF);
                int small = (int)(nIconSize >> 16);
                if (large <= 0) large = 32;
                if (small <= 0) small = 16;
                using (Bitmap b = Native.Fit(icon, large)) phiconLarge = b.GetHicon();
                using (Bitmap b = Native.Fit(icon, small)) phiconSmall = b.GetHicon();
                Native.Log("Extract " + large + "/" + small + " ok");
                return Native.S_OK;
            }
            catch (Exception ex) { Native.Log("Extract failed: " + ex); return Native.S_FALSE; }
        }
    }

    // ---------------------------------------------------------------- parti comuni

    // Stream di sola lettura, con Seek, sopra lo stream COM di Explorer (senza copiare tutto l'APK).
    sealed class ComStream : Stream
    {
        readonly IStream s;
        readonly long length;

        public ComStream(IStream s)
        {
            this.s = s;
            System.Runtime.InteropServices.ComTypes.STATSTG st;
            s.Stat(out st, 1); // STATFLAG_NONAME
            length = st.cbSize;
        }

        public override bool CanRead { get { return true; } }
        public override bool CanSeek { get { return true; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { return length; } }
        public override long Position { get { return Seek(0, SeekOrigin.Current); } set { Seek(value, SeekOrigin.Begin); } }
        public override void Flush() { }
        public override void SetLength(long value) { throw new NotSupportedException(); }
        public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }

        public override long Seek(long offset, SeekOrigin origin)
        {
            IntPtr p = Marshal.AllocCoTaskMem(8);
            try { s.Seek(offset, (int)origin, p); return Marshal.ReadInt64(p); }
            finally { Marshal.FreeCoTaskMem(p); }
        }

        public override int Read(byte[] buffer, int offset, int count)
        {
            byte[] tmp = offset == 0 ? buffer : new byte[count];
            IntPtr p = Marshal.AllocCoTaskMem(4);
            try
            {
                s.Read(tmp, count, p);
                int n = Marshal.ReadInt32(p);
                if (offset != 0 && n > 0) Buffer.BlockCopy(tmp, 0, buffer, offset, n);
                return n;
            }
            finally { Marshal.FreeCoTaskMem(p); }
        }
    }

    // Trova l'icona esatta come fa Android: AndroidManifest.xml (XML binario) indica la risorsa e resources.arsc
    // la associa a un file dell'APK. Funziona anche con i nomi delle risorse offuscati. Le icone adattive si
    // compongono da livelli bitmap o colore; i livelli vettoriali non sono supportati (restituisce null).
    static class ApkResolve
    {
        const ushort RES_STRING_POOL = 0x0001, RES_XML_START_ELEMENT = 0x0102, RES_XML_RESOURCE_MAP = 0x0180,
                     RES_TABLE_PACKAGE = 0x0200, RES_TABLE_TYPE = 0x0201;
        const byte TYPE_REFERENCE = 0x01, TYPE_STRING = 0x03;
        const uint ATTR_ICON = 0x01010002, ATTR_DRAWABLE = 0x01010199;
        const int MaxResourceBytes = 96 * 1024 * 1024;

        static ushort U16(byte[] b, int o) { return BitConverter.ToUInt16(b, o); }
        static uint U32(byte[] b, int o) { return BitConverter.ToUInt32(b, o); }

        static byte[] Read(ZipArchive zip, string name)
        {
            ZipArchiveEntry e = zip.GetEntry(name);
            if (e == null || e.Length > MaxResourceBytes) return null;
            using (Stream s = e.Open())
            using (var ms = new MemoryStream((int)e.Length))
            {
                s.CopyTo(ms);
                return ms.ToArray();
            }
        }

        sealed class Pool
        {
            readonly byte[] d; readonly int chunk, headerSize; readonly uint count, flags, stringsStart;
            public Pool(byte[] d, int chunk)
            {
                this.d = d; this.chunk = chunk;
                headerSize = U16(d, chunk + 2);
                count = U32(d, chunk + 8);
                flags = U32(d, chunk + 16);
                stringsStart = U32(d, chunk + 20);
            }
            public string Get(uint i)
            {
                if (i >= count) return null;
                int p = chunk + (int)stringsStart + (int)U32(d, chunk + headerSize + 4 * (int)i);
                if ((flags & 0x100) != 0)   // UTF-8
                {
                    int chars = d[p++]; if ((chars & 0x80) != 0) chars = ((chars & 0x7F) << 8) | d[p++];
                    int bytes = d[p++]; if ((bytes & 0x80) != 0) bytes = ((bytes & 0x7F) << 8) | d[p++];
                    return Encoding.UTF8.GetString(d, p, bytes);
                }
                int len = U16(d, p); p += 2;
                if ((len & 0x8000) != 0) { len = ((len & 0x7FFF) << 16) | U16(d, p); p += 2; }
                return Encoding.Unicode.GetString(d, p, len * 2);
            }
        }

        // ----- XML binario: scorre gli elementi e passa il riferimento dell'attributo cercato
        static void WalkXml(byte[] m, Func<string, uint, bool> onElement, uint wantedAttr)
        {
            Pool pool = null;
            uint[] resMap = null;
            int pos = U16(m, 2);                     // dimensione dell'header XML
            while (pos + 8 <= m.Length)
            {
                ushort type = U16(m, pos);
                int hs = U16(m, pos + 2);
                int cs = (int)U32(m, pos + 4);
                if (cs <= 0) break;
                if (type == RES_STRING_POOL) pool = new Pool(m, pos);
                else if (type == RES_XML_RESOURCE_MAP)
                {
                    resMap = new uint[(cs - hs) / 4];
                    for (int i = 0; i < resMap.Length; i++) resMap[i] = U32(m, pos + hs + 4 * i);
                }
                else if (type == RES_XML_START_ELEMENT && pool != null)
                {
                    string name = pool.Get(U32(m, pos + 20));
                    int attrStart = U16(m, pos + 24), attrSize = U16(m, pos + 26), attrCount = U16(m, pos + 28);
                    uint value = 0;
                    for (int i = 0; i < attrCount && resMap != null; i++)
                    {
                        int a = pos + 16 + attrStart + i * attrSize;
                        uint nameIdx = U32(m, a + 4);
                        if (nameIdx < resMap.Length && resMap[nameIdx] == wantedAttr && m[a + 15] == TYPE_REFERENCE) value = U32(m, a + 16);
                    }
                    if (onElement(name, value)) return;
                }
                pos += cs;
            }
        }

        // ----- resources.arsc
        struct Val { public int Density; public byte Type; public uint Data; }

        sealed class Table
        {
            readonly byte[] d;
            readonly Pool strings;
            readonly System.Collections.Generic.List<int> packages = new System.Collections.Generic.List<int>();

            public Table(byte[] data)
            {
                d = data;
                int pos = U16(d, 2);
                while (pos + 8 <= d.Length)
                {
                    ushort type = U16(d, pos);
                    int cs = (int)U32(d, pos + 4);
                    if (cs <= 0) break;
                    if (type == RES_STRING_POOL && strings == null) strings = new Pool(d, pos);
                    else if (type == RES_TABLE_PACKAGE) packages.Add(pos);
                    pos += cs;
                }
            }

            public string Str(uint i) { return strings == null ? null : strings.Get(i); }

            // tutte le configurazioni di una risorsa, seguendo i riferimenti
            public System.Collections.Generic.List<Val> Values(uint id, int depth = 0)
            {
                var res = new System.Collections.Generic.List<Val>();
                uint pkg = id >> 24; int typeId = (int)((id >> 16) & 0xFF); int entry = (int)(id & 0xFFFF);
                foreach (int pp in packages)
                {
                    if (U32(d, pp + 8) != pkg) continue;
                    int pend = pp + (int)U32(d, pp + 4);
                    int pos = pp + U16(d, pp + 2);
                    while (pos + 8 <= pend)
                    {
                        ushort type = U16(d, pos);
                        int hs = U16(d, pos + 2);
                        int cs = (int)U32(d, pos + 4);
                        if (cs <= 0) break;
                        if (type == RES_TABLE_TYPE && d[pos + 8] == typeId)
                        {
                            byte flags = d[pos + 9];
                            uint entryCount = U32(d, pos + 12);
                            uint entriesStart = U32(d, pos + 16);
                            int density = U16(d, pos + 34);      // ResTable_config.density
                            int offsets = pos + hs;
                            long entryOffset = -1;
                            if ((flags & 0x01) != 0)             // sparse: coppie (indice, offset/4)
                            {
                                for (int i = 0; i < entryCount; i++)
                                {
                                    uint v = U32(d, offsets + 4 * i);
                                    if ((v & 0xFFFF) == entry) { entryOffset = (long)(v >> 16) * 4; break; }
                                }
                            }
                            else if ((flags & 0x02) != 0)        // offset a 16 bit, in unità di 4
                            {
                                if (entry < entryCount) { ushort o = U16(d, offsets + 2 * entry); if (o != 0xFFFF) entryOffset = (long)o * 4; }
                            }
                            else if (entry < entryCount)
                            {
                                uint o = U32(d, offsets + 4 * entry);
                                if (o != 0xFFFFFFFF) entryOffset = o;
                            }
                            if (entryOffset >= 0)
                            {
                                int e = pos + (int)entriesStart + (int)entryOffset;
                                ushort eflags = U16(d, e + 2);
                                if ((eflags & 0x0001) == 0 && (eflags & 0x0008) == 0)   // né mappa (complessa) né voce compatta
                                {
                                    var v = new Val { Density = density, Type = d[e + 8 + 3], Data = U32(d, e + 8 + 4) };
                                    if (v.Type == TYPE_REFERENCE && depth < 5 && v.Data != 0) res.AddRange(Values(v.Data, depth + 1));
                                    else res.Add(v);
                                }
                            }
                        }
                        pos += cs;
                    }
                }
                return res;
            }
        }

        static int Rank(int density)
        {
            // prima le densità vere (più alta è meglio); anydpi (0xFFFE) e nodpi (0xFFFF) valgono ma vengono dopo
            if (density == 0xFFFE || density == 0xFFFF) return 1;
            return density == 0 ? 160 : density;
        }

        static string BestBitmapPath(Table t, System.Collections.Generic.List<Val> vals, ZipArchive zip)
        {
            string best = null; int bestRank = -1;
            foreach (Val v in vals)
            {
                if (v.Type != TYPE_STRING) continue;
                string p = t.Str(v.Data);
                if (p == null || !Regex.IsMatch(p, @"\.(png|webp|jpe?g)$", RegexOptions.IgnoreCase) || zip.GetEntry(p) == null) continue;
                int r = Rank(v.Density);
                if (r > bestRank) { best = p; bestRank = r; }
            }
            return best;
        }

        static Bitmap Layer(Table t, ZipArchive zip, uint id)
        {
            var vals = t.Values(id);
            string p = BestBitmapPath(t, vals, zip);
            if (p != null) return ApkIcon.Load(zip.GetEntry(p));
            foreach (Val v in vals)   // livello a tinta unita
            {
                if (v.Type == 0x1c || v.Type == 0x1d)
                {
                    var bmp = new Bitmap(108, 108, PixelFormat.Format32bppArgb);
                    using (var g = Graphics.FromImage(bmp)) g.Clear(Color.FromArgb(v.Type == 0x1d ? 255 : (int)(v.Data >> 24), (int)((v.Data >> 16) & 0xFF), (int)((v.Data >> 8) & 0xFF), (int)(v.Data & 0xFF)));
                    return bmp;
                }
            }
            return null;
        }

        public static Bitmap TryIcon(ZipArchive zip)
        {
            byte[] manifest = Read(zip, "AndroidManifest.xml");
            byte[] arsc = Read(zip, "resources.arsc");
            if (manifest == null || arsc == null) return null;

            uint iconId = 0;
            WalkXml(manifest, (name, value) => { if (name == "application") { iconId = value; return true; } return false; }, ATTR_ICON);
            if (iconId == 0) return null;

            var table = new Table(arsc);
            var vals = table.Values(iconId);

            // 1) un bitmap per l'icona stessa (icona classica, densità più alta)
            string path = BestBitmapPath(table, vals, zip);
            if (path != null) return ApkIcon.Load(zip.GetEntry(path));

            // 2) icona adattiva: un XML con i livelli <background> e <foreground>
            foreach (Val v in vals)
            {
                if (v.Type != TYPE_STRING) continue;
                string p = table.Str(v.Data);
                if (p == null || !p.EndsWith(".xml", StringComparison.OrdinalIgnoreCase)) continue;
                byte[] xml = Read(zip, p);
                if (xml == null) continue;
                uint bg = 0, fg = 0;
                WalkXml(xml, (name, value) =>
                {
                    if (name == "background") bg = value;
                    else if (name == "foreground") fg = value;
                    return false;
                }, ATTR_DRAWABLE);
                if (bg == 0 || fg == 0) continue;
                using (Bitmap back = Layer(table, zip, bg))
                using (Bitmap front = Layer(table, zip, fg))
                {
                    if (back == null || front == null) continue;
                    const int size = 432;
                    var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
                    using (var g = Graphics.FromImage(bmp))
                    {
                        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        var r = new Rectangle(-size / 4, -size / 4, size * 3 / 2, size * 3 / 2);   // i 72dp centrali dei 108dp
                        g.DrawImage(back, r);
                        g.DrawImage(front, r);
                    }
                    return bmp;
                }
            }
            return null;
        }
    }

    // Trova l'icona dell'APK: prima in modo esatto (ApkResolve), poi per nomi comuni se manifest e risorse
    // non si riescono a leggere.
    static class ApkIcon
    {
        static readonly string[] Bases = { "ic_launcher", "icon", "app_icon", "appicon", "ic_app", "logo" };
        static readonly Regex NotMain = new Regex("_(round|foreground|background|monochrome|notification|stat|small)$", RegexOptions.IgnoreCase);

        static int Density(string path)
        {
            Match m = Regex.Match(path, "-(xxxhdpi|xxhdpi|xhdpi|hdpi|mdpi|ldpi)");
            if (!m.Success) return 0;
            switch (m.Groups[1].Value)
            {
                case "xxxhdpi": return 6;
                case "xxhdpi": return 5;
                case "xhdpi": return 4;
                case "hdpi": return 3;
                case "mdpi": return 2;
                default: return 1;
            }
        }

        public static Bitmap Extract(ZipArchive zip)
        {
            try
            {
                Bitmap exact = ApkResolve.TryIcon(zip);
                if (exact != null) { Native.Log("icon found through manifest + resources.arsc"); return exact; }
            }
            catch (Exception ex) { Native.Log("manifest/arsc lookup failed: " + ex.Message); }

            var entries = zip.Entries.Where(e => e.FullName.StartsWith("res/", StringComparison.Ordinal)).ToList();

            // 1) icona bitmap classica, densità più alta
            foreach (string b in Bases)
            {
                var rx = new Regex("^res/[^/]+/" + Regex.Escape(b) + @"\.(png|webp|jpg)$", RegexOptions.IgnoreCase);
                var best = entries.Where(e => rx.IsMatch(e.FullName))
                                  .OrderByDescending(e => Density(e.FullName)).ThenByDescending(e => e.Length)
                                  .FirstOrDefault();
                if (best != null)
                {
                    try { return Load(best); } catch { }
                }
            }

            // 2) icona adattiva a due livelli bitmap
            foreach (string b in Bases)
            {
                var rxFg = new Regex("^res/([^/]+)/" + Regex.Escape(b) + @"_foreground\.(png|webp)$", RegexOptions.IgnoreCase);
                foreach (var fg in entries.Where(e => rxFg.IsMatch(e.FullName)).OrderByDescending(e => Density(e.FullName)))
                {
                    string dir = rxFg.Match(fg.FullName).Groups[1].Value;
                    var rxBg = new Regex("^res/" + Regex.Escape(dir) + "/" + Regex.Escape(b) + @"_background\.(png|webp)$", RegexOptions.IgnoreCase);
                    var bg = entries.FirstOrDefault(e => rxBg.IsMatch(e.FullName));
                    if (bg == null) continue;
                    try
                    {
                        using (Bitmap back = Load(bg))
                        using (Bitmap front = Load(fg))
                        {
                            const int size = 432;
                            var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
                            using (var g = Graphics.FromImage(bmp))
                            {
                                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                                // i livelli sono 108dp e se ne vedono 72 al centro: li disegno 1.5x
                                var r = new Rectangle(-size / 4, -size / 4, size * 3 / 2, size * 3 / 2);
                                g.DrawImage(back, r);
                                g.DrawImage(front, r);
                            }
                            return bmp;
                        }
                    }
                    catch { }
                }
            }

            // 3) qualunque altro bitmap che somigli all'icona del launcher
            var rxAny = new Regex(@"^res/[^/]+/([^/]*(launcher|app_?icon)[^/]*)\.(png|webp)$", RegexOptions.IgnoreCase);
            var any = entries.Where(e => { var m = rxAny.Match(e.FullName); return m.Success && !NotMain.IsMatch(m.Groups[1].Value); })
                             .OrderByDescending(e => Density(e.FullName)).ThenByDescending(e => e.Length)
                             .FirstOrDefault();
            if (any != null)
            {
                try { return Load(any); } catch { }
            }
            return null;
        }

        internal static Bitmap Load(ZipArchiveEntry e)
        {
            var ms = new MemoryStream();
            using (Stream s = e.Open()) s.CopyTo(ms);
            ms.Position = 0;
            if (e.FullName.EndsWith(".webp", StringComparison.OrdinalIgnoreCase)) return LoadWebp(ms);
            using (var tmp = new Bitmap(ms)) return new Bitmap(tmp);
        }

        // GDI+ non legge il WebP, WIC sì (se c'è il codec di Windows) e ci si arriva con WPF, che carico solo
        // quando serve, così gli APK solo PNG non lo portano nel processo.
        [MethodImpl(MethodImplOptions.NoInlining)]
        static Bitmap LoadWebp(MemoryStream ms)
        {
            var dec = System.Windows.Media.Imaging.BitmapDecoder.Create(ms,
                System.Windows.Media.Imaging.BitmapCreateOptions.PreservePixelFormat,
                System.Windows.Media.Imaging.BitmapCacheOption.OnLoad);
            var enc = new System.Windows.Media.Imaging.PngBitmapEncoder();
            enc.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(dec.Frames[0]));
            var png = new MemoryStream();
            enc.Save(png);
            png.Position = 0;
            using (var tmp = new Bitmap(png)) return new Bitmap(tmp);
        }
    }
}
