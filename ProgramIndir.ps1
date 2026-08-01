#Requires -Version 5.1
<#
.SYNOPSIS
    Toplu Program Indirici - coklu secim menusu + cok parcali paralel indirme.

.DESCRIPTION
    apps.json icindeki program listesini menu olarak gosterir, ok tuslari ile gezilir,
    Space ile secilir, Enter ile secilenlerin kurulum dosyalari indirilir.
    Kurulum YAPMAZ, sadece indirir.

    PowerShell 5.1 ve 7 ile ayni sekilde calisir. Admin yetkisi gerekmez.
    Harici bagimlilik yoktur (winget/choco/aria2c/BITS kullanilmaz).

    Hiz felsefesi: hicbir olcum, hiz testi veya ogrenilen profil yoktur. Paralel TCP
    baglantilari hattin o an ne veriyorsa onu alir. Ekrandaki hiz yalnizca bilgidir,
    hicbir karar ona bakilarak verilmez. Eszamanlilik sadece sunucu 429/503 dondugunde
    ve sadece kademeli olarak duser.

.PARAMETER AppsJson
    Program listesi dosyasi. Varsayilan: script klasorundeki apps.json

.PARAMETER Ayarlar
    Ayar dosyasi. Varsayilan: script klasorundeki ayarlar.json

.PARAMETER Klasor
    Indirilenlerin kaydedilecegi klasor. Varsayilan: script klasorundeki Indirilenler

.PARAMETER Parcalar
    Bir dosya icin acilacak paralel baglanti sayisi. ayarlar.json'u ezer.

.PARAMETER EsZamanli
    Ayni anda indirilecek program sayisi. ayarlar.json'u ezer.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\ProgramIndir.ps1

.EXAMPLE
    .\ProgramIndir.ps1 -Parcalar 8 -EsZamanli 2 -Klasor D:\Kurulumlar
#>

[CmdletBinding()]
param(
    [string]$AppsJson,
    [string]$Ayarlar,
    [string]$Klasor,

    [ValidateRange(1, 64)]
    [int]$Parcalar = 0,

    [ValidateRange(1, 8)]
    [int]$EsZamanli = 0,

    # Menuyu acmadan sadece fonksiyonlari yukler (dot-source / ileride GUI icin).
    [switch]$SadeceYukle
)

# ---------------------------------------------------------------------------
# 0. Ortam
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$script:KokKlasor = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $script:KokKlasor) { $script:KokKlasor = (Get-Location).Path }

if (-not $AppsJson) { $AppsJson = Join-Path $script:KokKlasor 'apps.json' }
if (-not $Ayarlar)  { $Ayarlar  = Join-Path $script:KokKlasor 'ayarlar.json' }

$script:LogYolu   = Join-Path $script:KokKlasor 'indirme-log.txt'
$script:Genislik  = 100
$script:Yukseklik = 30
$script:ImlecOk   = $true
$script:SonSatir  = 0
$script:MenuUyari = ''
$script:PanelOk   = $true
$script:PanelUst  = 0
$script:SonDuzYazi = [DateTime]::MinValue

function Initialize-Konsol {
    # Turkce karakterler ve kutu cizgileri icin UTF-8
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $global:OutputEncoding    = New-Object System.Text.UTF8Encoding($false)
    } catch { }

    # Eski Win10 build'lerinde varsayilan TLS 1.0'dir, HTTPS CDN'lere baglanamaz.
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
    # En kritik ayar: varsayilan 2'dir, ayarlanmazsa paralel segment acilamaz.
    try { [Net.ServicePointManager]::DefaultConnectionLimit = 256 }    catch { }
    try { [Net.ServicePointManager]::Expect100Continue      = $false } catch { }
    try { [Net.ServicePointManager]::UseNagleAlgorithm      = $false } catch { }

    [void](Update-KonsolOlcu)

    # ISE gibi ana bilgisayarlarda ReadKey / SetCursorPosition yoktur.
    try { [void][Console]::CursorTop } catch { $script:ImlecOk = $false }
    if ($Host.Name -like '*ISE*') { $script:ImlecOk = $false }
    if (-not $script:ImlecOk) { $script:PanelOk = $false }
}

function Update-KonsolOlcu {
    try {
        $g = [Console]::WindowWidth
        $y = [Console]::WindowHeight
        if ($g -lt 60) { $g = 100 }
        if ($y -lt 12) { $y = 30 }
    } catch { $g = 100; $y = 30 }
    $degisti = ($g -ne $script:Genislik) -or ($y -ne $script:Yukseklik)
    $script:Genislik  = $g
    $script:Yukseklik = $y
    return $degisti
}

function Write-Log {
    param([string]$Seviye, [string]$Mesaj)
    $satir = ('[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Seviye, $Mesaj)
    try {
        [IO.File]::AppendAllText($script:LogYolu, $satir + [Environment]::NewLine,
            (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# ---------------------------------------------------------------------------
# 1. Indirme motoru (inline C# / System.Net.Http)
# ---------------------------------------------------------------------------

$script:CSharpKaynak = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace TopluIndir
{
    // Sunucu "yavasla" dedi (429/503). Olcum degil, dogrudan yanit.
    public class RateLimitException : Exception
    {
        public RateLimitException(string m) : base(m) { }
    }

    // Dosyanin bir araligi. Is calma sirasinda End kuculur, yeni Segment dogar.
    public class Segment
    {
        public long Start;
        public long Position;    // yazilacak siradaki byte
        public long End;         // dahil
        public int  Splits;
        public bool Claimed;
        public bool Done;
    }

    public class Job
    {
        public string[] Urls;
        public string   Url;
        public int      UrlIndex;
        public string   FinalUrl;
        public string   Host = "";
        public string   OutPath;
        public string   TempPath;
        public string   StatePath;
        public string   SuggestedName;
        public long     Total = -1;
        public long     Received;
        public bool     AcceptRanges;
        public string   Encoded;
        public string   Fallback;
        public int      Parts = 1;          // sonunda olusan toplam segment sayisi
        public int      StartLimit = 1;     // baslangictaki eszamanlilik
        public int      ActiveLimit = 1;    // 429 sonrasi kalinan kademe
        public int      Steals;
        public int      Degrades;
        public bool     Resumed;
        public bool     Started;
        public bool     Finished;
        public bool     Success;
        public bool     Cancelled;
        public bool     CancelRequested;
        public bool     SaverStop;
        public string   Error = "";
        public DateTime StartUtc;
        public DateTime EndUtc;

        public readonly object Sync = new object();
        public readonly List<Segment> Segments = new List<Segment>();
        public CancellationTokenSource Cts = new CancellationTokenSource();
        public SemaphoreSlim Slots;

        public long GetReceived() { return Interlocked.Read(ref Received); }
        public void Add(long n)   { Interlocked.Add(ref Received, n); }
        public void SetReceived(long v) { Interlocked.Exchange(ref Received, v); }

        public void Cancel()
        {
            CancelRequested = true;
            try { Cts.Cancel(); } catch { }
        }

        public double ElapsedSeconds()
        {
            if (!Started) return 0;
            DateTime bit = Finished ? EndUtc : DateTime.UtcNow;
            return (bit - StartUtc).TotalSeconds;
        }

        public int SegmentCount()
        {
            lock (Sync) { return Segments.Count; }
        }
    }

    public static class Engine
    {
        private static HttpClient _client;
        private static readonly object _lock = new object();

        public static string UserAgent =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
        public static int  BufferSize    = 1048576;   // 1 MB
        public static int  PartRetry     = 3;
        public static long StealMinBytes = 8388608;   // 8 MB'tan az kalmissa bolme
        public static int  MaxSplits     = 3;         // bir parca en fazla 3 kez bolunur
        // FileStream useAsync. Olculdu: acikken 16 parcali indirme 4-7 kat YAVAS
        // (9,9-16,4 MB/s karsi 63,8-71,4 MB/s). Sebep: her yazmadan once Position
        // atamasi tamponlu async FileStream'de senkron flush/seek zorluyor ve 16
        // thread ayni handle uzerinde ustuste binen overlapped yazmalarda seri hale
        // geliyor. ayarlar.json > asenkronDosya ile acilabilir.
        public static bool AsyncFile     = false;

        private static FileOptions FileOpts()
        {
            return AsyncFile
                ? (FileOptions.Asynchronous | FileOptions.SequentialScan)
                : FileOptions.SequentialScan;
        }

        private static void WriteBlock(FileStream fs, byte[] buf, int n)
        {
            if (AsyncFile) fs.WriteAsync(buf, 0, n).Wait();
            else fs.Write(buf, 0, n);
        }

        private static readonly Version Http11 = new Version(1, 1);

        // Tek instance. Her indirmede new HttpClient() soket tuketir.
        public static HttpClient Client
        {
            get
            {
                lock (_lock)
                {
                    if (_client == null)
                    {
                        HttpClientHandler h = new HttpClientHandler();
                        h.AllowAutoRedirect = true;
                        h.MaxAutomaticRedirections = 10;
                        try { h.MaxConnectionsPerServer = 256; } catch { }
                        // Sikistirma KAPALI + Accept-Encoding: identity.
                        // gzip acilinca diske yazilan boyut Content-Length ile uyusmaz,
                        // Range offsetleri ve boyut dogrulamasi bozulur.
                        try { h.AutomaticDecompression = DecompressionMethods.None; } catch { }
                        _client = new HttpClient(h);
                        _client.Timeout = TimeSpan.FromMinutes(60);
                        _client.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", UserAgent);
                        _client.DefaultRequestHeaders.TryAddWithoutValidation("Accept", "*/*");
                        _client.DefaultRequestHeaders.TryAddWithoutValidation("Accept-Encoding", "identity");
                    }
                    return _client;
                }
            }
        }

        private static HttpRequestMessage NewRequest(HttpMethod m, string url)
        {
            HttpRequestMessage r = new HttpRequestMessage(m, url);
            // HTTP/2 tek TCP uzerinden cogullar; parcali indirmede ayri TCP
            // baglantilarinin pencere buyumesini engeller. PS 5.1 ve PS 7 ayni olsun.
            r.Version = Http11;
            return r;
        }

        public static string Flatten(Exception ex)
        {
            List<string> parts = new List<string>();
            AggregateException agg = ex as AggregateException;
            if (agg != null)
            {
                foreach (Exception e in agg.Flatten().InnerExceptions) parts.Add(Flatten(e));
                return string.Join(" | ", parts.ToArray());
            }
            while (ex != null) { parts.Add(ex.Message); ex = ex.InnerException; }
            return string.Join(" -> ", parts.ToArray());
        }

        private static bool IsCancel(Exception ex)
        {
            AggregateException agg = ex as AggregateException;
            if (agg != null)
            {
                foreach (Exception e in agg.Flatten().InnerExceptions) if (IsCancel(e)) return true;
                return false;
            }
            while (ex != null)
            {
                if (ex is OperationCanceledException) return true;
                ex = ex.InnerException;
            }
            return false;
        }

        // ---- Kesif ----------------------------------------------------------
        // Yedek link destegi: sirayla dener, ilk calisani kullanir.
        public static Job Probe(string[] urls)
        {
            string son = "";
            for (int i = 0; i < urls.Length; i++)
            {
                try
                {
                    Job j = Inspect(urls[i]);
                    j.Urls = urls;
                    j.UrlIndex = i;
                    return j;
                }
                catch (Exception ex)
                {
                    son = Flatten(ex);
                    if (i < urls.Length - 1) continue;
                }
            }
            throw new Exception(son);
        }

        // Range: bytes=0-0 ile GET. Tek istekte: yonlendirme sonrasi gercek URL,
        // toplam boyut, Range destegi, Content-Disposition adi.
        public static Job Inspect(string url)
        {
            Job j = new Job();
            j.Url = url;
            j.FinalUrl = url;

            HttpResponseMessage resp = null;
            try
            {
                HttpRequestMessage req = NewRequest(HttpMethod.Get, url);
                req.Headers.Range = new RangeHeaderValue(0, 0);
                resp = Client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead).Result;
                if (!resp.IsSuccessStatusCode)
                {
                    int sc = (int)resp.StatusCode;
                    resp.Dispose();
                    resp = null;
                    if (sc == 404) throw new Exception("Baglanti bulunamadi (HTTP 404)");
                    if (sc == 429 || sc == 503) throw new Exception("Sunucu mesgul (HTTP " + sc + ")");
                }
            }
            catch (Exception ex)
            {
                if (resp != null) { resp.Dispose(); resp = null; }
                string m = Flatten(ex);
                if (m.IndexOf("HTTP 404") >= 0 || m.IndexOf("HTTP 429") >= 0 || m.IndexOf("HTTP 503") >= 0) throw;
            }

            if (resp == null)
            {
                HttpRequestMessage req = NewRequest(HttpMethod.Head, url);
                try { resp = Client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead).Result; }
                catch (Exception ex) { throw new Exception(Flatten(ex)); }
            }

            if (!resp.IsSuccessStatusCode)
            {
                resp.Dispose();
                HttpRequestMessage req = NewRequest(HttpMethod.Get, url);
                resp = Client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead).Result;
            }

            using (resp)
            {
                if (!resp.IsSuccessStatusCode)
                    throw new Exception("Sunucu HTTP " + (int)resp.StatusCode + " " + resp.ReasonPhrase + " dondu");

                if (resp.RequestMessage != null && resp.RequestMessage.RequestUri != null)
                {
                    j.FinalUrl = resp.RequestMessage.RequestUri.AbsoluteUri;
                    j.Host = resp.RequestMessage.RequestUri.Host;
                }

                if ((int)resp.StatusCode == 206)
                {
                    j.AcceptRanges = true;
                    if (resp.Content.Headers.ContentRange != null &&
                        resp.Content.Headers.ContentRange.Length.HasValue)
                        j.Total = resp.Content.Headers.ContentRange.Length.Value;
                }
                else
                {
                    if (resp.Content.Headers.ContentLength.HasValue)
                        j.Total = resp.Content.Headers.ContentLength.Value;
                    foreach (string v in resp.Headers.AcceptRanges)
                        if (string.Equals(v, "bytes", StringComparison.OrdinalIgnoreCase)) j.AcceptRanges = true;
                }

                // Istemedigimiz halde sikistirilmis govde geldiyse Range offsetleri
                // sikistirilmis byte'lara aittir; parcali indirme bozuk dosya uretir.
                foreach (string enc in resp.Content.Headers.ContentEncoding)
                {
                    if (!string.Equals(enc, "identity", StringComparison.OrdinalIgnoreCase))
                    {
                        j.Encoded = enc;
                        j.AcceptRanges = false;
                        j.Total = -1;
                    }
                }

                string name = null;
                try
                {
                    ContentDispositionHeaderValue cd = resp.Content.Headers.ContentDisposition;
                    if (cd != null)
                    {
                        name = cd.FileNameStar;
                        if (string.IsNullOrEmpty(name)) name = cd.FileName;
                        if (!string.IsNullOrEmpty(name)) name = name.Trim('"', ' ');
                    }
                }
                catch { name = null; }

                if (string.IsNullOrEmpty(name))
                {
                    try
                    {
                        Uri u = new Uri(j.FinalUrl);
                        string p = Uri.UnescapeDataString(u.AbsolutePath);
                        int slash = p.LastIndexOf('/');
                        if (slash >= 0 && slash < p.Length - 1) name = p.Substring(slash + 1);
                    }
                    catch { }
                }
                j.SuggestedName = name;
            }
            return j;
        }

        // ---- Yarim dosya ----------------------------------------------------
        // Devam edilebilir mi? Edilebiliyorsa kac byte hazir oldugunu dondurur, yoksa -1.
        public static long InspectResume(string outPath, long total)
        {
            try
            {
                string temp = outPath + ".indiriliyor";
                string state = temp + ".durum";
                if (!File.Exists(temp) || !File.Exists(state)) return -1;

                FileInfo fi = new FileInfo(temp);
                // On-tahsisli dosya tam boyutta olmali; degilse veya buyukse bozuktur.
                if (total <= 0 || fi.Length != total) return -1;

                string[] lines = File.ReadAllLines(state);
                if (lines.Length < 3 || lines[0] != "v1") return -1;
                long kayitliToplam;
                if (!long.TryParse(lines[1], out kayitliToplam)) return -1;
                if (kayitliToplam != total) return -1;

                long hazir = 0;
                for (int i = 3; i < lines.Length; i++)
                {
                    if (lines[i].Length == 0) continue;
                    string[] p = lines[i].Split(',');
                    if (p.Length != 3) return -1;
                    long s = long.Parse(p[0]), pos = long.Parse(p[1]), e = long.Parse(p[2]);
                    if (pos < s || pos > e + 1) return -1;
                    hazir += (pos - s);
                }
                return hazir;
            }
            catch { return -1; }
        }

        public static void DropPartial(string outPath)
        {
            try { if (File.Exists(outPath + ".indiriliyor")) File.Delete(outPath + ".indiriliyor"); } catch { }
            try { if (File.Exists(outPath + ".indiriliyor.durum")) File.Delete(outPath + ".indiriliyor.durum"); } catch { }
        }

        private static bool TryLoadState(Job j)
        {
            try
            {
                if (!File.Exists(j.StatePath) || !File.Exists(j.TempPath)) return false;
                FileInfo fi = new FileInfo(j.TempPath);
                if (fi.Length != j.Total) return false;

                string[] lines = File.ReadAllLines(j.StatePath);
                if (lines.Length < 4 || lines[0] != "v1") return false;
                if (long.Parse(lines[1]) != j.Total) return false;

                long hazir = 0;
                lock (j.Sync)
                {
                    j.Segments.Clear();
                    for (int i = 3; i < lines.Length; i++)
                    {
                        if (lines[i].Length == 0) continue;
                        string[] p = lines[i].Split(',');
                        Segment s = new Segment();
                        s.Start = long.Parse(p[0]);
                        s.Position = long.Parse(p[1]);
                        s.End = long.Parse(p[2]);
                        s.Done = (s.Position > s.End);
                        hazir += (s.Position - s.Start);
                        j.Segments.Add(s);
                    }
                    if (j.Segments.Count == 0) return false;
                }
                j.SetReceived(hazir);
                j.Resumed = true;
                return true;
            }
            catch { return false; }
        }

        private static void SaveState(Job j)
        {
            try
            {
                StringBuilder sb = new StringBuilder();
                sb.AppendLine("v1");
                sb.AppendLine(j.Total.ToString());
                sb.AppendLine(j.FinalUrl);
                lock (j.Sync)
                {
                    foreach (Segment s in j.Segments)
                        sb.AppendLine(s.Start + "," + s.Position + "," + s.End);
                }
                File.WriteAllText(j.StatePath, sb.ToString());
            }
            catch { }
        }

        // ---- Indirme --------------------------------------------------------
        public static void Start(Job j, string outPath, int maxParts, bool resume)
        {
            j.OutPath   = outPath;
            j.TempPath  = outPath + ".indiriliyor";
            j.StatePath = j.TempPath + ".durum";
            j.StartUtc  = DateTime.UtcNow;
            j.Started   = true;

            Task.Factory.StartNew(delegate
            {
                try { Run(j, maxParts, resume); j.Success = true; }
                catch (Exception ex)
                {
                    j.Success = false;
                    if (j.CancelRequested || IsCancel(ex)) { j.Cancelled = true; j.Error = "Iptal edildi"; }
                    else { j.Error = Flatten(ex); }
                }
                finally
                {
                    j.SaverStop = true;
                    j.EndUtc = DateTime.UtcNow;
                    // Kademe dusurmede izin tuketen yardimci gorevleri serbest birak.
                    try { j.Cts.Cancel(); } catch { }
                    j.Finished = true;
                }
            }, TaskCreationOptions.LongRunning);
        }

        private static void Run(Job j, int maxParts, bool resume)
        {
            long total = j.Total;
            bool segmented = j.AcceptRanges && total > 0 && maxParts > 1 && j.Encoded == null;

            string dir = Path.GetDirectoryName(j.TempPath);
            if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) Directory.CreateDirectory(dir);

            if (!segmented)
            {
                if (!resume) { try { if (File.Exists(j.TempPath)) File.Delete(j.TempPath); } catch { } }
                j.Parts = 1; j.StartLimit = 1; j.ActiveLimit = 1;
                SingleStream(j);
            }
            else
            {
                try { Segmented(j, total, maxParts, resume); }
                catch (Exception ex)
                {
                    if (j.CancelRequested || IsCancel(ex)) throw;
                    // Kademe 1'e kadar indi ve hala olmadi: son care tek akis.
                    j.Fallback = "Parcali indirme basarisiz, tek akisa dusuldu: " + Flatten(ex);
                    j.Parts = 1; j.ActiveLimit = 1;
                    j.SetReceived(0);
                    try { if (File.Exists(j.TempPath)) File.Delete(j.TempPath); } catch { }
                    SingleStream(j);
                }
            }

            if (File.Exists(j.OutPath)) File.Delete(j.OutPath);
            File.Move(j.TempPath, j.OutPath);
            try { if (File.Exists(j.StatePath)) File.Delete(j.StatePath); } catch { }
        }

        private static void Segmented(Job j, long total, int parts, bool resume)
        {
            bool yuklendi = false;
            if (resume) yuklendi = TryLoadState(j);

            if (!yuklendi)
            {
                // On-tahsis: disk parcalanmasini ve yeniden boyutlandirmayi onler.
                using (FileStream pre = new FileStream(j.TempPath, FileMode.Create, FileAccess.Write, FileShare.ReadWrite))
                    pre.SetLength(total);

                long chunk = total / parts;
                lock (j.Sync)
                {
                    j.Segments.Clear();
                    for (int i = 0; i < parts; i++)
                    {
                        Segment s = new Segment();
                        s.Start = i * chunk;
                        s.Position = s.Start;
                        s.End = (i == parts - 1) ? (total - 1) : (s.Start + chunk - 1);
                        j.Segments.Add(s);
                    }
                }
                j.SetReceived(0);
            }

            j.StartLimit  = parts;
            j.ActiveLimit = parts;
            j.Slots = new SemaphoreSlim(parts, parts);
            j.SaverStop = false;

            // Durum kaydedici: Ctrl+C sonrasi devam edebilmek icin.
            Task saver = Task.Factory.StartNew(delegate
            {
                while (!j.SaverStop)
                {
                    SaveState(j);
                    Thread.Sleep(1000);
                }
            }, TaskCreationOptions.LongRunning);

            Task[] workers = new Task[parts];
            for (int i = 0; i < parts; i++)
                workers[i] = Task.Factory.StartNew(delegate { WorkerLoop(j); }, TaskCreationOptions.LongRunning);

            try { Task.WaitAll(workers); }
            finally
            {
                j.SaverStop = true;
                SaveState(j);
                j.Parts = j.SegmentCount();
            }

            lock (j.Sync)
            {
                foreach (Segment s in j.Segments)
                    if (s.Position <= s.End)
                        throw new Exception("Eksik parca " + s.Start + "-" + s.End + " (kalan " + (s.End - s.Position + 1) + " byte)");
            }
        }

        private static void WorkerLoop(Job j)
        {
            CancellationToken ct = j.Cts.Token;
            while (!ct.IsCancellationRequested)
            {
                Segment seg;
                lock (j.Sync) { seg = ClaimOrStealLocked(j); }
                if (seg == null) return;

                int rl = 0;
                while (true)
                {
                    bool held = false;
                    try
                    {
                        j.Slots.Wait(ct);
                        held = true;
                        DownloadSegment(j, seg);
                        break;
                    }
                    catch (RateLimitException)
                    {
                        if (held) { j.Slots.Release(); held = false; }
                        Reduce(j);
                        rl++;
                        if (rl > 6) throw new Exception("Sunucu israrla 429/503 donuyor");
                        Thread.Sleep(2000 * rl);
                    }
                    finally { if (held) j.Slots.Release(); }
                }
            }
        }

        // Sahipsiz parca varsa onu al; yoksa en cok byte'i kalani ikiye bol (is calma).
        private static Segment ClaimOrStealLocked(Job j)
        {
            foreach (Segment s in j.Segments)
                if (!s.Claimed && !s.Done) { s.Claimed = true; return s; }

            Segment kurban = null;
            long enCok = 0;
            foreach (Segment s in j.Segments)
            {
                if (s.Done) continue;
                long kalan = s.End - s.Position + 1;
                if (kalan > enCok && kalan > StealMinBytes && s.Splits < MaxSplits)
                {
                    enCok = kalan;
                    kurban = s;
                }
            }
            if (kurban == null) return null;

            long yeniBas = kurban.End - (enCok / 2) + 1;
            if (yeniBas <= kurban.Position) return null;

            Segment ns = new Segment();
            ns.Start    = yeniBas;
            ns.Position = yeniBas;
            ns.End      = kurban.End;
            ns.Claimed  = true;
            ns.Splits   = kurban.Splits + 1;

            kurban.End = yeniBas - 1;
            kurban.Splits++;
            j.Segments.Add(ns);
            j.Steals++;
            return ns;
        }

        // Eszamanliligi yarila: 16 -> 8 -> 4 -> 2 -> 1. Basarili kademede kalinir.
        private static void Reduce(Job j)
        {
            int azalt = 0;
            lock (j.Sync)
            {
                if (j.ActiveLimit <= 1) return;
                int yeni = j.ActiveLimit / 2;
                azalt = j.ActiveLimit - yeni;
                j.ActiveLimit = yeni;
                j.Degrades++;
            }
            for (int i = 0; i < azalt; i++)
            {
                // Izni kalici olarak tuket: bir daha Release edilmez.
                Task.Factory.StartNew(delegate
                {
                    try { j.Slots.Wait(j.Cts.Token); } catch { }
                }, TaskCreationOptions.LongRunning);
            }
        }

        private static int ReadSync(Stream s, byte[] b, int count, CancellationToken ct)
        {
            try { return s.ReadAsync(b, 0, count, ct).Result; }
            catch (AggregateException ae)
            {
                Exception inner = ae.Flatten().InnerException;
                if (inner != null) throw inner;
                throw;
            }
        }

        private static void DownloadSegment(Job j, Segment seg)
        {
            CancellationToken ct = j.Cts.Token;
            int attempt = 0;

            while (true)
            {
                attempt++;
                long bas, son;
                lock (j.Sync) { bas = seg.Position; son = seg.End; }
                if (bas > son) { lock (j.Sync) { seg.Done = true; } return; }

                try
                {
                    HttpRequestMessage req = NewRequest(HttpMethod.Get, j.FinalUrl);
                    req.Headers.Range = new RangeHeaderValue(bas, son);

                    using (HttpResponseMessage resp = Client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct).Result)
                    {
                        int sc = (int)resp.StatusCode;
                        if (sc == 429 || sc == 503) throw new RateLimitException("HTTP " + sc);
                        if (sc != 206) throw new Exception("Sunucu parcali istegi reddetti (HTTP " + sc + ")");

                        using (Stream s = resp.Content.ReadAsStreamAsync().Result)
                        using (FileStream fs = new FileStream(j.TempPath, FileMode.Open, FileAccess.Write,
                                   FileShare.ReadWrite, BufferSize, FileOpts()))
                        {
                            byte[] buf = new byte[BufferSize];
                            while (true)
                            {
                                if (ct.IsCancellationRequested) throw new OperationCanceledException();

                                long pos, izin;
                                lock (j.Sync) { pos = seg.Position; izin = seg.End - pos + 1; }
                                if (izin <= 0) break;

                                int iste = (int)Math.Min(izin, (long)buf.Length);
                                int n = ReadSync(s, buf, iste, ct);
                                if (n <= 0) break;

                                // Okuma sirasinda baskasi bu parcayi caldiysa fazlasini at.
                                lock (j.Sync) { izin = seg.End - seg.Position + 1; }
                                if (n > izin) n = (int)izin;
                                if (n <= 0) break;

                                fs.Position = pos;
                                WriteBlock(fs, buf, n);
                                lock (j.Sync) { seg.Position += n; }
                                j.Add(n);
                            }
                        }
                    }

                    bool bitti;
                    lock (j.Sync) { bitti = seg.Position > seg.End; if (bitti) seg.Done = true; }
                    if (bitti) return;
                    throw new Exception("Baglanti erken kapandi");
                }
                catch (RateLimitException) { throw; }
                catch (Exception ex)
                {
                    if (ct.IsCancellationRequested || IsCancel(ex)) throw new OperationCanceledException();
                    if (attempt >= PartRetry)
                        throw new Exception("Parca " + seg.Start + "-" + seg.End + ": " + Flatten(ex));
                    Thread.Sleep(500 * (int)Math.Pow(2, attempt - 1));
                }
            }
        }

        // Range desteklenmiyorsa: tek akis, ResponseHeadersRead + 1 MB buffer.
        private static void SingleStream(Job j)
        {
            CancellationToken ct = j.Cts.Token;
            HttpRequestMessage req = NewRequest(HttpMethod.Get, j.FinalUrl);

            using (HttpResponseMessage resp = Client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct).Result)
            {
                if (!resp.IsSuccessStatusCode)
                    throw new Exception("Sunucu HTTP " + (int)resp.StatusCode + " " + resp.ReasonPhrase + " dondu");

                string enc = null;
                foreach (string e in resp.Content.Headers.ContentEncoding)
                    if (!string.Equals(e, "identity", StringComparison.OrdinalIgnoreCase)) enc = e.ToLowerInvariant();

                if (enc == null && resp.Content.Headers.ContentLength.HasValue)
                    j.Total = resp.Content.Headers.ContentLength.Value;
                else if (enc != null)
                    j.Total = -1;

                using (Stream raw = resp.Content.ReadAsStreamAsync().Result)
                {
                    Stream s = raw;
                    if (enc == "gzip")         s = new System.IO.Compression.GZipStream(raw, System.IO.Compression.CompressionMode.Decompress);
                    else if (enc == "deflate") s = new System.IO.Compression.DeflateStream(raw, System.IO.Compression.CompressionMode.Decompress);

                    try
                    {
                        using (FileStream fs = new FileStream(j.TempPath, FileMode.Create, FileAccess.Write,
                                   FileShare.Read, BufferSize, FileOpts()))
                        {
                            byte[] buf = new byte[BufferSize];
                            while (true)
                            {
                                if (ct.IsCancellationRequested) throw new OperationCanceledException();
                                int n = ReadSync(s, buf, buf.Length, ct);
                                if (n <= 0) break;
                                WriteBlock(fs, buf, n);
                                j.Add(n);
                            }
                        }
                    }
                    finally { if (!object.ReferenceEquals(s, raw)) s.Dispose(); }
                }
            }
        }
    }
}
'@

function Initialize-Motor {
    if ('TopluIndir.Engine' -as [type]) { return }

    $refs = @('System.Net.Http')
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $refs = @(
            'System.Net.Http', 'System.Net.Primitives', 'System.Runtime',
            'System.Collections', 'System.Threading', 'System.Threading.Tasks',
            'System.IO.FileSystem', 'System.IO.Compression', 'System.Linq', 'netstandard'
        )
    }

    try {
        Add-Type -TypeDefinition $script:CSharpKaynak -ReferencedAssemblies $refs -Language CSharp -ErrorAction Stop
    } catch {
        Add-Type -TypeDefinition $script:CSharpKaynak -Language CSharp -ErrorAction Stop
    }
}

# ---------------------------------------------------------------------------
# 2. Ayarlar
# ---------------------------------------------------------------------------

function Get-Ayarlar {
    param([string]$Yol)

    $a = [pscustomobject]@{
        parcaSayisi         = 16
        esZamanliProgram    = 3
        isCalmaEnAzMB       = 8
        isCalmaEnFazlaBolme = 3
        asenkronDosya       = $false
        indirmeKlasoru      = ''
    }

    if (Test-Path -LiteralPath $Yol) {
        try {
            $v = (Get-Content -LiteralPath $Yol -Raw -Encoding UTF8) | ConvertFrom-Json
            foreach ($alan in 'parcaSayisi','esZamanliProgram','isCalmaEnAzMB','isCalmaEnFazlaBolme','asenkronDosya','indirmeKlasoru') {
                if ($null -ne $v.$alan -and "$($v.$alan)" -ne '') { $a.$alan = $v.$alan }
            }
        } catch {
            Write-Log 'UYARI' "ayarlar.json okunamadi, varsayilanlar kullanildi: $($_.Exception.Message)"
        }
    }

    if ($a.parcaSayisi -lt 1 -or $a.parcaSayisi -gt 64) { $a.parcaSayisi = 16 }
    if ($a.esZamanliProgram -lt 1 -or $a.esZamanliProgram -gt 8) { $a.esZamanliProgram = 3 }
    if ($a.isCalmaEnAzMB -lt 1) { $a.isCalmaEnAzMB = 8 }
    if ($a.isCalmaEnFazlaBolme -lt 0) { $a.isCalmaEnFazlaBolme = 3 }
    return $a
}

# ---------------------------------------------------------------------------
# 3. Bicimlendirme
# ---------------------------------------------------------------------------

function Format-Boyut {
    param([long]$Bayt)
    if ($Bayt -lt 0)          { return '—' }
    if ($Bayt -lt 1024)       { return ('{0} B' -f $Bayt) }
    if ($Bayt -lt 1048576)    { return ('{0:N1} KB' -f ($Bayt / 1KB)) }
    if ($Bayt -lt 1073741824) { return ('{0:N1} MB' -f ($Bayt / 1MB)) }
    return ('{0:N2} GB' -f ($Bayt / 1GB))
}

function Format-Hiz {
    param([double]$BaytSaniye)
    if ($BaytSaniye -le 0) { return '—' }
    if ($BaytSaniye -lt 1048576) { return ('{0:N0} KB/s' -f ($BaytSaniye / 1KB)) }
    return ('{0:N0} MB/s' -f ($BaytSaniye / 1MB))
}

function Format-Sure {
    param([double]$Saniye)
    if ($Saniye -lt 0 -or [double]::IsInfinity($Saniye) -or [double]::IsNaN($Saniye)) { return '--:--' }
    if ($Saniye -gt 359999) { return '99:59' }
    $ts = [TimeSpan]::FromSeconds([Math]::Round($Saniye))
    if ($ts.TotalHours -ge 1) { return ('{0:00}:{1:00}:{2:00}' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds) }
    return ('{0:00}:{1:00}' -f $ts.Minutes, $ts.Seconds)
}

function Get-GuvenliDosyaAdi {
    param([string]$Ad)
    if ([string]::IsNullOrWhiteSpace($Ad)) { return $null }
    $q = $Ad.IndexOf('?')
    if ($q -ge 0) { $Ad = $Ad.Substring(0, $q) }
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $Ad = $Ad.Replace($c, '_') }
    $Ad = $Ad.Trim()
    if ([string]::IsNullOrWhiteSpace($Ad)) { return $null }
    if (-not [IO.Path]::GetExtension($Ad)) { $Ad = $Ad + '.exe' }
    return $Ad
}

function ConvertTo-SadeHata {
    param([string]$Ham)
    if (-not $Ham) { return 'Bilinmeyen hata' }
    $m = $Ham
    if ($m -match 'HTTP 404')    { return 'Baglanti bulunamadi (404). apps.json icindeki url guncel degil.' }
    if ($m -match 'HTTP 40[13]') { return 'Sunucu erisimi reddetti (403/401).' }
    if ($m -match 'HTTP (429|503)|429/503') { return 'Sunucu mesgul veya hiz siniri uyguluyor.' }
    if ($m -match 'HTTP 5\d\d')  { return 'Sunucu hatasi (5xx). Daha sonra tekrar dene.' }
    # .NET mesajlari isletim sistemi diline gore gelir; hem TR hem EN kaliplari.
    if ($m -match 'No such host|remote name|Uzak ad|bilinen bir ana|ana bilgisayar') { return 'Sunucu adi cozulemedi. Internet baglantisini kontrol et.' }
    if ($m -match 'timed out|zaman aşımı|zaman asimi|TaskCanceled')                  { return 'Baglanti zaman asimina ugradi.' }
    if ($m -match 'SSL|secure channel|güvenli kanal|sertifika|certificate')          { return 'Guvenli baglanti kurulamadi (TLS/sertifika).' }
    if ($m -match 'unable to connect|refused|bağlantı kapatıldı|bağlantı kurulamadı|reddedildi') { return 'Sunucuya baglanilamadi. Internet baglantisini kontrol et.' }
    $ilk = ($m -split '(\r?\n| \| | -> )')[0]
    if ($ilk.Length -gt 140) { $ilk = $ilk.Substring(0, 140) + '...' }
    return $ilk
}

# ---------------------------------------------------------------------------
# 4. apps.json
# ---------------------------------------------------------------------------

function Get-Programlar {
    param([string]$Yol)

    if (-not (Test-Path -LiteralPath $Yol)) { throw "Program listesi bulunamadi: $Yol" }

    try { $ham = Get-Content -LiteralPath $Yol -Raw -Encoding UTF8 }
    catch { throw "apps.json okunamadi: $($_.Exception.Message)" }

    try { $veri = $ham | ConvertFrom-Json }
    catch { throw "apps.json gecerli JSON degil: $($_.Exception.Message)" }

    $liste = @()
    if ($veri.programlar) { $liste = @($veri.programlar) }
    elseif ($veri -is [array]) { $liste = @($veri) }

    $temiz = @()
    $sira = 0
    foreach ($p in $liste) {
        $sira++
        # url tek string de olabilir, yedek linkler icin dizi de.
        $urls = @()
        if ($p.url -is [array]) {
            foreach ($u in $p.url) { $t = ([string]$u).Trim(); if ($t) { $urls += $t } }
        } elseif ($p.url) {
            $t = ([string]$p.url).Trim(); if ($t) { $urls += $t }
        }

        if ([string]::IsNullOrWhiteSpace($p.ad) -or $urls.Count -eq 0) {
            Write-Log 'UYARI' "apps.json kayit #$sira atlandi (ad veya url bos)"
            continue
        }

        $temiz += [pscustomobject]@{
            ad       = [string]$p.ad
            urls     = [string[]]$urls
            dosya    = [string]$p.dosya
            aciklama = [string]$p.aciklama
        }
    }

    if ($temiz.Count -eq 0) { throw "apps.json icinde gecerli program kaydi yok." }
    return ,$temiz
}

# ---------------------------------------------------------------------------
# 5. Menu
# ---------------------------------------------------------------------------

function Write-Pad {
    param([array]$Parcalar)
    $kalan = $script:Genislik - 1
    foreach ($p in $Parcalar) {
        if ($kalan -le 0) { break }
        $t = [string]$p.t
        if ($t.Length -gt $kalan) { $t = $t.Substring(0, $kalan) }
        $renk = $p.c
        if (-not $renk) { $renk = 'Gray' }
        Write-Host $t -NoNewline -ForegroundColor $renk
        $kalan -= $t.Length
    }
    if ($kalan -gt 0) { Write-Host (' ' * $kalan) -NoNewline }
    Write-Host ''
}

# Tum tus okumalari buradan gecer. $script:TestTuslari doluysa oradan beslenir,
# boylece menu otomatik test edilebilir.
function Read-Tus {
    if ($script:TestTuslari -and $script:TestTuslari.Count -gt 0) { return $script:TestTuslari.Dequeue() }
    return [Console]::ReadKey($true)
}

# Cikti yonlendirilmisse PS 7'nin Clear-Host'u RawUI'ye dokunup patlar; sarmalanir.
function Clear-Ekran {
    try { Clear-Host } catch { try { [Console]::Clear() } catch { Write-Host '' } }
}

function Move-Basa {
    if ($script:ImlecOk) {
        try { [Console]::SetCursorPosition(0, 0); return } catch { $script:ImlecOk = $false }
    }
    Clear-Ekran
}

function Show-Menu {
    param([array]$Apps)

    $n      = $Apps.Count
    $secili = New-Object 'bool[]' $n
    $imlec  = 0                        # 0..n-1 program, n = "Secilenleri Indir"
    $ust    = 0
    $araYazi  = ''
    $araZaman = [DateTime]::MinValue

    # Q ile baslayan program varsa Q arama harfidir; cikis Esc'e birakilir.
    $qCikis = $true
    foreach ($a in $Apps) { if ($a.ad -like 'q*') { $qCikis = $false; break } }

    Clear-Ekran
    $script:SonSatir = 0

    while ($true) {
        if (Update-KonsolOlcu) { Clear-Ekran; $script:SonSatir = 0 }

        # Basliklar 5 + alt bilgi 6 satir; kalani listeye ver.
        $pencere = $script:Yukseklik - 11
        if ($pencere -lt 3) { $pencere = 3 }
        if ($pencere -gt $n) { $pencere = $n }

        if ($imlec -lt $n) {
            if ($imlec -lt $ust) { $ust = $imlec }
            if ($imlec -ge $ust + $pencere) { $ust = $imlec - $pencere + 1 }
        }
        $enUst = [Math]::Max(0, $n - $pencere)
        if ($ust -lt 0) { $ust = 0 }
        if ($ust -gt $enUst) { $ust = $enUst }

        $secimSayisi = 0
        for ($i = 0; $i -lt $n; $i++) { if ($secili[$i]) { $secimSayisi++ } }

        $cikisTus = if ($qCikis) { 'Q' } else { 'Esc' }
        $satirlar = @()
        $satirlar += ,@(@{ t = ''; c = 'Gray' })
        $satirlar += ,@(@{ t = '  TOPLU PROGRAM INDIRICI'; c = 'Cyan' })
        $satirlar += ,@(@{ t = '  Hangi programlari indirmek istersin?'; c = 'White' })
        $satirlar += ,@(@{ t = ('  (↑↓ gez · Space sec · Ctrl+A hepsi · yaz=ara · Home/End/PgUp/PgDn · Enter indir · {0} cikis)' -f $cikisTus); c = 'DarkGray' })
        $satirlar += ,@(@{ t = ''; c = 'Gray' })

        if ($ust -gt 0) {
            $satirlar += ,@(@{ t = ('    ↑ {0} program daha' -f $ust); c = 'DarkGray' })
        } else {
            $satirlar += ,@(@{ t = ''; c = 'Gray' })
        }

        for ($i = $ust; $i -lt [Math]::Min($n, $ust + $pencere); $i++) {
            $isaret = if ($secili[$i]) { '[X] ' } else { '[ ] ' }
            $okChar = if ($i -eq $imlec) { '> ' } else { '  ' }
            $adRenk = if ($i -eq $imlec) { 'Yellow' } elseif ($secili[$i]) { 'Green' } else { 'Gray' }
            $satir  = @(
                @{ t = '  ' + $okChar; c = 'Yellow' },
                @{ t = $isaret;        c = $(if ($secili[$i]) { 'Green' } else { 'DarkGray' }) },
                @{ t = $Apps[$i].ad;   c = $adRenk }
            )
            if ($Apps[$i].aciklama) { $satir += @{ t = '  — ' + $Apps[$i].aciklama; c = 'DarkGray' } }
            if ($Apps[$i].urls.Count -gt 1) { $satir += @{ t = '  [yedek link]'; c = 'DarkCyan' } }
            $satirlar += ,$satir
        }

        $gizliAlt = $n - ($ust + $pencere)
        if ($gizliAlt -gt 0) {
            $satirlar += ,@(@{ t = ('    ↓ {0} program daha' -f $gizliAlt); c = 'DarkGray' })
        } else {
            $satirlar += ,@(@{ t = ''; c = 'Gray' })
        }

        $satirlar += ,@(@{ t = ''; c = 'Gray' })
        $indirRenk = if ($imlec -eq $n) { 'Yellow' } else { 'DarkGray' }
        $satirlar += ,@(
            @{ t = $(if ($imlec -eq $n) { '  > ' } else { '    ' }); c = 'Yellow' },
            @{ t = ('Secilenleri Indir ({0})' -f $secimSayisi); c = $indirRenk }
        )

        if ($araYazi) {
            $satirlar += ,@(@{ t = ('  Ara: {0}' -f $araYazi); c = 'DarkCyan' })
        } elseif ($script:MenuUyari) {
            $satirlar += ,@(@{ t = $script:MenuUyari; c = 'Red' })
        } else {
            $satirlar += ,@(@{ t = ''; c = 'Gray' })
        }

        Move-Basa
        $ciz = [Math]::Max($satirlar.Count, $script:SonSatir)
        for ($i = 0; $i -lt $ciz; $i++) {
            if ($i -lt $satirlar.Count) { Write-Pad $satirlar[$i] } else { Write-Pad @(@{ t = ''; c = 'Gray' }) }
        }
        $script:SonSatir = $satirlar.Count

        $tus = Read-Tus
        $ctrl = ($tus.Modifiers -band [ConsoleModifiers]::Control) -ne 0

        if ($ctrl -and $tus.Key -eq 'A') {
            $script:MenuUyari = ''; $araYazi = ''
            $hepsi = ($secimSayisi -eq $n)
            for ($i = 0; $i -lt $n; $i++) { $secili[$i] = -not $hepsi }
            continue
        }
        if ($ctrl) { continue }

        $islendi = $true
        switch ($tus.Key) {
            'UpArrow'    { $imlec--; if ($imlec -lt 0)  { $imlec = $n } }
            'DownArrow'  { $imlec++; if ($imlec -gt $n) { $imlec = 0 } }
            'Home'       { $imlec = 0; $ust = 0 }
            'End'        { $imlec = $n }
            'PageUp'     { $imlec = [Math]::Max(0, $imlec - $pencere) }
            'PageDown'   { $imlec = [Math]::Min($n, $imlec + $pencere) }
            'Spacebar'   { if ($imlec -lt $n) { $secili[$imlec] = -not $secili[$imlec] } }
            'Backspace'  { $araYazi = '' }
            'Escape'     { return $null }
            'Enter'      {
                $sonuc = @()
                for ($i = 0; $i -lt $n; $i++) { if ($secili[$i]) { $sonuc += $i } }
                if ($sonuc.Count -eq 0) {
                    $script:MenuUyari = '  ! Hicbir program secili degil. Space ile sec.'
                } else {
                    return ,$sonuc
                }
            }
            default      { $islendi = $false }
        }

        if ($islendi) { $script:MenuUyari = ''; $araYazi = ''; continue }

        if ($qCikis -and $tus.Key -eq 'Q') { return $null }

        # Yazarak arama: 300 ms icinde basilan harfler birlestirilir.
        $ch = $tus.KeyChar
        if ($ch -and [char]::IsLetterOrDigit($ch)) {
            $script:MenuUyari = ''
            $simdi = [DateTime]::Now
            if (($simdi - $araZaman).TotalMilliseconds -gt 300) { $araYazi = '' }
            $araYazi += $ch
            $araZaman = $simdi

            $bul = -1
            for ($i = 0; $i -lt $n; $i++) { if ($Apps[$i].ad -like "$araYazi*") { $bul = $i; break } }
            if ($bul -lt 0) {
                $araYazi = [string]$ch
                for ($i = 0; $i -lt $n; $i++) { if ($Apps[$i].ad -like "$araYazi*") { $bul = $i; break } }
            }
            if ($bul -ge 0) { $imlec = $bul }
        }
    }
}

# ---------------------------------------------------------------------------
# 6. Hazirlik: kesif, dosya adi, cakisma, yarim dosya
# ---------------------------------------------------------------------------

function Read-Secim {
    param([string]$Soru, [hashtable]$Secenekler, [string]$Varsayilan)
    Write-Host $Soru -ForegroundColor Yellow
    Write-Host ('  ' + (($Secenekler.Keys | Sort-Object | ForEach-Object { "[$_] $($Secenekler[$_])" }) -join '   ')) -ForegroundColor DarkGray
    while ($true) {
        $t = Read-Tus
        $k = [string]$t.Key
        if ($Secenekler.ContainsKey($k)) { return $k }
        if ($t.Key -eq 'Escape' -or $t.Key -eq 'Enter') { return $Varsayilan }
    }
}

function Get-BosDosyaYolu {
    param([string]$Yol)
    $dizin  = Split-Path -Parent $Yol
    $ad     = [IO.Path]::GetFileNameWithoutExtension($Yol)
    $uzanti = [IO.Path]::GetExtension($Yol)
    $i = 1
    while ($true) {
        $yeni = Join-Path $dizin ('{0} ({1}){2}' -f $ad, $i, $uzanti)
        if (-not (Test-Path -LiteralPath $yeni)) { return $yeni }
        $i++
    }
}

function New-IndirmeIsi {
    param($App, [string]$Hedef)

    $is = [pscustomobject]@{
        Ad       = $App.ad
        App      = $App
        Job      = $null
        Yol      = ''
        Host     = ''
        Devam    = $false
        Durum    = 'Bekliyor'
        Sonuc    = $null
        Ornekler = $null
        TepeHiz  = 0.0
    }

    Write-Host ('  {0} ... ' -f $App.ad) -NoNewline -ForegroundColor Gray

    $job = $null
    $hata = ''
    for ($d = 1; $d -le 3; $d++) {
        try { $job = [TopluIndir.Engine]::Probe([string[]]$App.urls); $hata = ''; break }
        catch {
            $hata = $_.Exception.GetBaseException().Message
            $job = $null
            if ($d -lt 3) { Start-Sleep -Seconds ([Math]::Pow(2, $d - 1)) }
        }
    }

    if (-not $job) {
        $kisa = ConvertTo-SadeHata $hata
        Write-Host ('HATA: {0}' -f $kisa) -ForegroundColor Red
        Write-Log 'HATA' ("{0} kesif basarisiz: {1}" -f $App.ad, $hata)
        $is.Durum = 'HATA'
        $is.Sonuc = New-Sonuc -Ad $App.ad -Durum 'HATA' -Mesaj $kisa
        return $is
    }

    $is.Job  = $job
    $is.Host = if ($job.Host) { $job.Host } else { ([Uri]$job.FinalUrl).Host }

    $dosyaAdi = Get-GuvenliDosyaAdi $App.dosya
    if (-not $dosyaAdi) { $dosyaAdi = Get-GuvenliDosyaAdi $job.SuggestedName }
    if (-not $dosyaAdi) { $dosyaAdi = Get-GuvenliDosyaAdi ($App.ad -replace '\s+', '-') }
    $yol = Join-Path $Hedef $dosyaAdi

    $ek = ''
    if ($job.UrlIndex -gt 0) { $ek = (' · yedek link #{0}' -f ($job.UrlIndex + 1)) }
    Write-Host ('{0}  {1}{2}' -f (Split-Path -Leaf $yol), (Format-Boyut $job.Total), $ek) -ForegroundColor DarkGray

    # Yarim dosya var mi?
    $hazir = [TopluIndir.Engine]::InspectResume($yol, $job.Total)
    if (Test-Path -LiteralPath ($yol + '.indiriliyor')) {
        if ($hazir -ge 0 -and $job.AcceptRanges) {
            $k = Read-Secim -Soru ('    Yarim dosya bulundu ({0} inmis).' -f (Format-Boyut $hazir)) `
                            -Secenekler @{ 'D' = 'Devam et'; 'B' = 'Bastan indir'; 'S' = 'Sil ve atla' } -Varsayilan 'D'
            switch ($k) {
                'D' { $is.Devam = $true }
                'B' { [TopluIndir.Engine]::DropPartial($yol) }
                'S' { [TopluIndir.Engine]::DropPartial($yol)
                      $is.Durum = 'Atlandi'
                      $is.Sonuc = New-Sonuc -Ad $App.ad -Durum 'Atlandi' -Mesaj 'Yarim dosya silindi'
                      return $is }
            }
        } else {
            $sebep = if (-not $job.AcceptRanges) { 'sunucu Range desteklemiyor' } else { 'yarim dosya kaydi gecersiz' }
            Write-Host ('    Yarim dosya devam ettirilemiyor ({0}), bastan indirilecek.' -f $sebep) -ForegroundColor DarkYellow
            [TopluIndir.Engine]::DropPartial($yol)
        }
    }

    # Hedef dosya cakismasi
    if (Test-Path -LiteralPath $yol) {
        $k = Read-Secim -Soru '    Dosya zaten var.' `
                        -Secenekler @{ 'U' = 'Uzerine yaz'; 'A' = 'Atla'; 'Y' = 'Yeniden adlandir' } -Varsayilan 'A'
        switch ($k) {
            'A' { $is.Durum = 'Atlandi'
                  $is.Sonuc = New-Sonuc -Ad $App.ad -Durum 'Atlandi' -Mesaj 'Dosya zaten var'
                  return $is }
            'Y' { $yol = Get-BosDosyaYolu $yol }
        }
    }

    $is.Yol = $yol
    return $is
}

function New-Sonuc {
    param([string]$Ad, [string]$Durum, [string]$Mesaj = '', [string]$Boyut = '—', [string]$Sure = '—',
          [string]$Hiz = '—', [string]$Tepe = '—', [string]$Parca = '—', [string]$Imza = '—', [long]$Bayt = 0)
    return [pscustomobject]@{
        Ad = $Ad; Durum = $Durum; Boyut = $Boyut; Sure = $Sure; Hiz = $Hiz
        Tepe = $Tepe; Parca = $Parca; Imza = $Imza; Mesaj = $Mesaj; Bayt = $Bayt
    }
}

function Resolve-Dns {
    param([array]$Hostlar)
    $benzersiz = $Hostlar | Where-Object { $_ } | Select-Object -Unique
    if (-not $benzersiz) { return }
    $gorevler = @()
    foreach ($h in $benzersiz) {
        try { $gorevler += [Net.Dns]::GetHostAddressesAsync($h) } catch { }
    }
    foreach ($g in $gorevler) { try { [void]$g.Wait(3000) } catch { } }
    Write-Log 'BILGI' ("DNS onceden cozuldu: {0}" -f ($benzersiz -join ', '))
}

# ---------------------------------------------------------------------------
# 7. Indirme paneli ve zamanlayici
# ---------------------------------------------------------------------------

function Get-AnlikHiz {
    param($Is)
    $simdi  = Get-Date
    $alinan = $Is.Job.GetReceived()
    [void]$Is.Ornekler.Add([pscustomobject]@{ Zaman = $simdi; Bayt = $alinan })
    # Anlik hiz son ~2 saniyeden, toplam ortalamadan degil.
    while ($Is.Ornekler.Count -gt 1 -and ($simdi - $Is.Ornekler[0].Zaman).TotalSeconds -gt 2.0) {
        $Is.Ornekler.RemoveAt(0)
    }
    $hiz = 0.0
    if ($Is.Ornekler.Count -gt 1) {
        $dt = ($simdi - $Is.Ornekler[0].Zaman).TotalSeconds
        if ($dt -gt 0) { $hiz = ($alinan - $Is.Ornekler[0].Bayt) / $dt }
    }
    if ($hiz -gt $Is.TepeHiz) { $Is.TepeHiz = $hiz }
    return $hiz
}

function Format-PanelSatiri {
    param($Is, [double]$Hiz)

    $ad = $Is.Ad
    if ($ad.Length -gt 14) { $ad = $ad.Substring(0, 14) }
    $ad = $ad.PadRight(14)

    $alinan = $Is.Job.GetReceived()
    $toplam = $Is.Job.Total
    $barG   = 18
    if ($toplam -gt 0) { $oran = [Math]::Min(1.0, $alinan / [double]$toplam) } else { $oran = 0 }
    $dolu = [int][Math]::Floor($oran * $barG)
    $bar  = ('█' * $dolu) + ('░' * ($barG - $dolu))
    $yuzde = if ($toplam -gt 0) { ('{0,3:N0}%' -f ($oran * 100)) } else { '  ?%' }

    $kalan = ''
    if ($toplam -gt 0 -and $Hiz -gt 0) { $kalan = ('{0} kaldi' -f (Format-Sure (($toplam - $alinan) / $Hiz))) }

    $seg = ''
    if ($Is.Job.SegmentCount() -gt 1) { $seg = ('{0}p' -f $Is.Job.SegmentCount()) }

    return ('  {0} [{1}] {2}  {3}  {4}  {5}  {6}' -f
        $ad, $bar, $yuzde,
        (Format-Boyut $alinan).PadLeft(9),
        (Format-Hiz $Hiz).PadLeft(9),
        $seg.PadLeft(4),
        $kalan)
}

function Reserve-Panel {
    param([int]$Yukseklik)
    if (-not $script:PanelOk) { return }
    try {
        for ($i = 0; $i -lt $Yukseklik; $i++) { Write-Host (' ' * ($script:Genislik - 1)) }
        $script:PanelUst = [Console]::CursorTop - $Yukseklik
    } catch {
        # Cikti yonlendirilmisse konsol tanitici yoktur; duz satir moduna gec.
        $script:PanelOk = $false
    }
}

function Write-Panel {
    param([array]$Satirlar, [int]$Yukseklik)

    if (-not $script:PanelOk) {
        # Yedek mod: imleci oynatamiyoruz, 5 saniyede bir tek satir ozet bas.
        if (((Get-Date) - $script:SonDuzYazi).TotalSeconds -lt 5) { return }
        $script:SonDuzYazi = Get-Date
        foreach ($s in $Satirlar) { if ($s.t) { Write-Host $s.t -ForegroundColor $s.c } }
        return
    }

    try { [Console]::SetCursorPosition(0, $script:PanelUst) } catch { $script:PanelOk = $false; return }
    $en = $script:Genislik - 1
    for ($i = 0; $i -lt $Yukseklik; $i++) {
        $t = if ($i -lt $Satirlar.Count) { [string]$Satirlar[$i].t } else { '' }
        $c = if ($i -lt $Satirlar.Count -and $Satirlar[$i].c) { $Satirlar[$i].c } else { 'Gray' }
        if ($t.Length -gt $en) { $t = $t.Substring(0, $en) }
        $t = $t.PadRight($en)
        if ($i -eq $Yukseklik - 1) { Write-Host $t -ForegroundColor $c -NoNewline }
        else { Write-Host $t -ForegroundColor $c }
    }
}

function Write-Kalici {
    param([string]$Metin, [string]$Renk, [int]$PanelYukseklik)
    if (-not $script:PanelOk) { Write-Host $Metin -ForegroundColor $Renk; return }
    try { [Console]::SetCursorPosition(0, $script:PanelUst) } catch { $script:PanelOk = $false }
    if (-not $script:PanelOk) { Write-Host $Metin -ForegroundColor $Renk; return }
    $en = $script:Genislik - 1
    $t = $Metin
    if ($t.Length -gt $en) { $t = $t.Substring(0, $en) }
    Write-Host $t.PadRight($en) -ForegroundColor $Renk
    Reserve-Panel $PanelYukseklik
}

function Start-IndirmeKuyrugu {
    param([array]$Isler, [int]$EsZamanli, [int]$Parcalar, [string]$Hedef)

    $bekleyen  = New-Object System.Collections.ArrayList
    foreach ($is in $Isler) { if ($is.Durum -eq 'Bekliyor') { [void]$bekleyen.Add($is) } }
    $aktif     = New-Object System.Collections.ArrayList
    $sonuclar  = New-Object System.Collections.ArrayList
    foreach ($is in $Isler) { if ($is.Sonuc) { [void]$sonuclar.Add($is.Sonuc) } }

    $panelY = $EsZamanli + 3
    Write-Host ''
    Reserve-Panel $panelY

    $tamamlandi = $false
    try {
        while ($bekleyen.Count -gt 0 -or $aktif.Count -gt 0) {

            # --- baslatilabilecekleri baslat (ayni host'a iki dosya asla eszamanli degil)
            while ($aktif.Count -lt $EsZamanli) {
                $aktifHostlar = @($aktif | ForEach-Object { $_.Host })
                $aday = $null
                foreach ($b in $bekleyen) {
                    if ($aktifHostlar -notcontains $b.Host) { $aday = $b; break }
                }
                if (-not $aday) { break }
                $bekleyen.Remove($aday)
                $aday.Ornekler = New-Object System.Collections.ArrayList
                $aday.Durum = 'Iniyor'
                [TopluIndir.Engine]::Start($aday.Job, $aday.Yol, $Parcalar, $aday.Devam)
                [void]$aktif.Add($aday)
                Write-Log 'BILGI' ("Baslatildi: {0} <- {1} ({2} parca, devam={3})" -f $aday.Ad, $aday.Job.FinalUrl, $Parcalar, $aday.Devam)
            }

            Start-Sleep -Milliseconds 250

            # --- panel
            $satirlar = @()
            $toplamHiz = 0.0
            foreach ($a in $aktif) {
                $h = Get-AnlikHiz -Is $a
                $toplamHiz += $h
                $satirlar += @{ t = (Format-PanelSatiri -Is $a -Hiz $h); c = 'Cyan' }
            }
            while ($satirlar.Count -lt $EsZamanli) { $satirlar += @{ t = ''; c = 'Gray' } }
            $satirlar += @{ t = ('  ' + ('─' * [Math]::Min(76, $script:Genislik - 4))); c = 'DarkGray' }
            $satirlar += @{ t = ('  {0} {1}   ·   {2} aktif, {3} kuyrukta, {4} bitti' -f
                                'TOPLAM'.PadRight(14), (Format-Hiz $toplamHiz).PadLeft(9),
                                $aktif.Count, $bekleyen.Count, $sonuclar.Count); c = 'White' }
            $satirlar += @{ t = ''; c = 'Gray' }
            Write-Panel -Satirlar $satirlar -Yukseklik $panelY

            # --- bitenler
            $bitenler = @($aktif | Where-Object { $_.Job.Finished })
            foreach ($b in $bitenler) {
                $aktif.Remove($b)
                $s = Complete-Indirme -Is $b
                [void]$sonuclar.Add($s)
                $renk = switch ($s.Durum) { 'Tamamlandi' { 'Green' } 'Atlandi' { 'DarkGray' } default { 'Red' } }
                $isaret = if ($s.Durum -eq 'Tamamlandi') { '✓' } else { '✗' }
                $metin = ('  {0} {1}  {2}  {3}  ort {4}  tepe {5}' -f
                            $isaret, $b.Ad.PadRight(14), $s.Durum.PadRight(11), $s.Boyut.PadLeft(9), $s.Hiz, $s.Tepe)
                if ($s.Mesaj) { $metin += ('  ·  {0}' -f $s.Mesaj) }
                Write-Kalici -Metin $metin -Renk $renk -PanelYukseklik $panelY
            }
        }
        $tamamlandi = $true
    }
    finally {
        if (-not $tamamlandi) {
            # Ctrl+C: aktif indirmeler iptal, yarim dosyalar diskte kalir.
            foreach ($a in $aktif) { $a.Job.Cancel() }
            $bekle = [Diagnostics.Stopwatch]::StartNew()
            while (($aktif | Where-Object { -not $_.Job.Finished }) -and $bekle.Elapsed.TotalSeconds -lt 8) {
                Start-Sleep -Milliseconds 200
            }
            try { [Console]::SetCursorPosition(0, $script:PanelUst) } catch { }
            Write-Host ''
            Write-Host '  Iptal edildi. Yarim dosyalar diskte birakildi:' -ForegroundColor Yellow
            foreach ($a in $aktif) {
                Write-Host ('    {0} — {1} indi ({2})' -f $a.Ad, (Format-Boyut $a.Job.GetReceived()),
                            (Split-Path -Leaf ($a.Yol + '.indiriliyor'))) -ForegroundColor DarkYellow
                Write-Log 'UYARI' ("{0} iptal edildi, {1} byte yarim kaldi" -f $a.Ad, $a.Job.GetReceived())
            }
            Write-Host '  Script tekrar calistirildiginda "Devam et" secenegi sunulacak.' -ForegroundColor DarkGray
            Write-Host ''
        }
    }

    return ,@($sonuclar)
}

# ---------------------------------------------------------------------------
# 8. Dogrulama
# ---------------------------------------------------------------------------

function Test-IndirilenDosya {
    param([string]$Yol, [long]$BeklenenBoyut)

    $sonuc = [pscustomobject]@{ Gecerli = $true; Imza = '—'; Uyari = '' }

    $fi = Get-Item -LiteralPath $Yol
    if ($fi.Length -le 0) {
        $sonuc.Gecerli = $false; $sonuc.Uyari = 'Dosya bos (0 bayt)'; return $sonuc
    }
    if ($BeklenenBoyut -gt 0 -and $fi.Length -ne $BeklenenBoyut) {
        $sonuc.Gecerli = $false
        $sonuc.Uyari = ('Boyut uyusmuyor ({0} / beklenen {1})' -f $fi.Length, $BeklenenBoyut)
        return $sonuc
    }

    # Ilk iki bayt MZ mi? Degilse CDN'den HTML hata sayfasi gelmis olabilir.
    $bas = New-Object byte[] 4
    $fs = [IO.File]::OpenRead($Yol)
    try { [void]$fs.Read($bas, 0, 4) } finally { $fs.Dispose() }

    if ($bas[0] -eq 0x4D -and $bas[1] -eq 0x5A) {
        # MZ - calistirilabilir
    } elseif ($bas[0] -eq 0x3C) {
        $sonuc.Gecerli = $false
        $sonuc.Uyari = 'Icerik HTML gorunuyor (indirme linki bir sayfa olabilir)'
        return $sonuc
    } elseif ($bas[0] -eq 0xD0 -and $bas[1] -eq 0xCF) { $sonuc.Uyari = 'MSI/OLE dosyasi (exe degil)' }
    elseif ($bas[0] -eq 0x50 -and $bas[1] -eq 0x4B)   { $sonuc.Uyari = 'ZIP arsivi (exe degil)' }
    else { $sonuc.Uyari = 'Bilinmeyen dosya turu (MZ imzasi yok)' }

    try { $sonuc.Imza = [string](Get-AuthenticodeSignature -LiteralPath $Yol -ErrorAction Stop).Status }
    catch { $sonuc.Imza = 'Kontrol edilemedi' }

    return $sonuc
}

function Complete-Indirme {
    param($Is)

    $job = $Is.Job

    if ($job.Cancelled) {
        Write-Log 'UYARI' ("{0} iptal edildi" -f $Is.Ad)
        return New-Sonuc -Ad $Is.Ad -Durum 'Iptal' -Mesaj 'Kullanici iptal etti'
    }

    if (-not $job.Success) {
        $kisa = ConvertTo-SadeHata $job.Error
        Write-Log 'HATA' ("{0} basarisiz: {1}" -f $Is.Ad, $job.Error)
        return New-Sonuc -Ad $Is.Ad -Durum 'HATA' -Mesaj $kisa
    }

    $sure   = $job.ElapsedSeconds()
    $alinan = (Get-Item -LiteralPath $Is.Yol).Length
    $ortHiz = if ($sure -gt 0.4) { Format-Hiz ($job.GetReceived() / $sure) } else { '—' }
    $tepe   = if ($Is.TepeHiz -gt 0) { Format-Hiz $Is.TepeHiz } else { '—' }

    # Parca sutunu: baslangic + is calma, 429 olduysa dusulen kademe.
    $parca = [string]$job.StartLimit
    if ($job.Steals -gt 0)   { $parca += ('+{0}' -f $job.Steals) }
    if ($job.Degrades -gt 0) { $parca += ('→{0}' -f $job.ActiveLimit) }

    $dogrulama = Test-IndirilenDosya -Yol $Is.Yol -BeklenenBoyut $job.Total

    $mesajlar = @()
    if ($job.Resumed) { $mesajlar += 'yarim dosyadan devam edildi' }
    if ($job.Fallback) {
        $mesajlar += 'sunucu parcali indirmeyi reddetti, tek akis'
        Write-Log 'UYARI' ("{0} {1}" -f $Is.Ad, $job.Fallback)
    }
    if ($job.Degrades -gt 0) {
        $mesajlar += ('429/503 nedeniyle {0} kademesine dusuldu' -f $job.ActiveLimit)
        Write-Log 'UYARI' ("{0} eszamanlilik {1} -> {2}" -f $Is.Ad, $job.StartLimit, $job.ActiveLimit)
    }
    if ($job.UrlIndex -gt 0) { $mesajlar += ('yedek link #{0} kullanildi' -f ($job.UrlIndex + 1)) }
    if ($dogrulama.Uyari) { $mesajlar += $dogrulama.Uyari }
    if ($dogrulama.Imza -ne 'Valid') { $mesajlar += ('imza: {0}' -f $dogrulama.Imza) }

    $durum = if ($dogrulama.Gecerli) { 'Tamamlandi' } else { 'HATA' }
    if (-not $dogrulama.Gecerli) { Write-Log 'HATA' ("{0} dogrulama basarisiz: {1}" -f $Is.Ad, $dogrulama.Uyari) }
    else {
        Write-Log 'BILGI' ("{0} tamamlandi: {1} ({2}, ort {3}, tepe {4}, parca {5}, calma {6}, imza {7})" -f
            $Is.Ad, $Is.Yol, (Format-Boyut $alinan), $ortHiz, $tepe, $parca, $job.Steals, $dogrulama.Imza)
    }

    return New-Sonuc -Ad $Is.Ad -Durum $durum -Boyut (Format-Boyut $alinan) -Sure (Format-Sure $sure) `
                     -Hiz $ortHiz -Tepe $tepe -Parca $parca -Imza $dogrulama.Imza `
                     -Mesaj ($mesajlar -join ' · ') -Bayt $alinan
}

# ---------------------------------------------------------------------------
# 9. Ozet
# ---------------------------------------------------------------------------

function Show-Ozet {
    param([array]$Sonuclar, [string]$Hedef, [double]$OturumSaniye)

    $cizgi = '─' * [Math]::Min(96, $script:Genislik - 4)
    Write-Host ''
    Write-Host ('  {0}' -f $cizgi) -ForegroundColor DarkGray

    $adG = 7
    foreach ($s in $Sonuclar) { if ($s.Ad.Length -gt $adG) { $adG = $s.Ad.Length } }
    if ($adG -gt 22) { $adG = 22 }

    Write-Host ('  {0}  {1}  {2}  {3}  {4}  {5}  {6}  {7}' -f
        'Program'.PadRight($adG), 'Durum'.PadRight(11), 'Boyut'.PadRight(10),
        'Sure'.PadRight(8), 'Ort.Hiz'.PadRight(9), 'Tepe'.PadRight(9),
        'Parca'.PadRight(7), 'Imza') -ForegroundColor White
    Write-Host ('  {0}' -f $cizgi) -ForegroundColor DarkGray

    foreach ($s in $Sonuclar) {
        $ad = $s.Ad
        if ($ad.Length -gt $adG) { $ad = $ad.Substring(0, $adG) }
        $renk = switch ($s.Durum) {
            'Tamamlandi' { 'Green' }
            'Atlandi'    { 'DarkGray' }
            'Iptal'      { 'DarkYellow' }
            default      { 'Red' }
        }
        Write-Host ('  {0}  {1}  {2}  {3}  {4}  {5}  {6}  {7}' -f
            $ad.PadRight($adG), $s.Durum.PadRight(11), $s.Boyut.PadRight(10),
            $s.Sure.PadRight(8), $s.Hiz.PadRight(9), $s.Tepe.PadRight(9),
            $s.Parca.PadRight(7), $s.Imza) -ForegroundColor $renk
        if ($s.Mesaj) { Write-Host ('  {0}  {1}' -f (' ' * $adG), $s.Mesaj) -ForegroundColor DarkYellow }
    }

    Write-Host ('  {0}' -f $cizgi) -ForegroundColor DarkGray

    $ok    = @($Sonuclar | Where-Object { $_.Durum -eq 'Tamamlandi' }).Count
    $atlan = @($Sonuclar | Where-Object { $_.Durum -eq 'Atlandi' }).Count
    $iptal = @($Sonuclar | Where-Object { $_.Durum -eq 'Iptal' }).Count
    $kotu  = @($Sonuclar | Where-Object { $_.Durum -eq 'HATA' }).Count
    $bayt  = 0
    foreach ($s in $Sonuclar) { $bayt += $s.Bayt }

    $ozet = ('  {0} basarili, {1} basarisiz' -f $ok, $kotu)
    if ($atlan -gt 0) { $ozet += (', {0} atlandi' -f $atlan) }
    if ($iptal -gt 0) { $ozet += (', {0} iptal' -f $iptal) }
    Write-Host $ozet -ForegroundColor $(if ($kotu -gt 0) { 'Yellow' } else { 'Green' })

    $ortalama = if ($OturumSaniye -gt 0.4) { Format-Hiz ($bayt / $OturumSaniye) } else { '—' }
    Write-Host ('  Oturum: {0} · {1} · ortalama {2}' -f (Format-Boyut $bayt), (Format-Sure $OturumSaniye), $ortalama) -ForegroundColor Cyan
    Write-Host ('  Klasor: {0}' -f $Hedef) -ForegroundColor DarkGray
    if ($kotu -gt 0) { Write-Host ('  Ayrinti: {0}' -f $script:LogYolu) -ForegroundColor DarkGray }
    Write-Host ''

    Write-Log 'BILGI' ("Oturum ozeti: {0} basarili, {1} basarisiz, {2} atlandi, {3} iptal, toplam {4}, sure {5}" -f
        $ok, $kotu, $atlan, $iptal, (Format-Boyut $bayt), (Format-Sure $OturumSaniye))
}

function Request-KlasorAc {
    param([string]$Hedef)
    Write-Host '  Klasoru acmak ister misin? (E/H) ' -ForegroundColor White -NoNewline
    while ($true) {
        $t = Read-Tus
        if ($t.Key -eq 'E' -or $t.Key -eq 'Y') {
            Write-Host 'E'
            try { Invoke-Item -LiteralPath $Hedef } catch { Write-Host ('  Klasor acilamadi: {0}' -f $_.Exception.Message) -ForegroundColor Red }
            return
        }
        if ($t.Key -eq 'H' -or $t.Key -eq 'N' -or $t.Key -eq 'Escape' -or $t.Key -eq 'Enter') {
            Write-Host 'H'; return
        }
    }
}

# ---------------------------------------------------------------------------
# 10. Ana akis
# ---------------------------------------------------------------------------

function Start-Uygulama {
    Initialize-Konsol

    if (-not $script:ImlecOk) {
        Write-Host ''
        Write-Host '  Bu script PowerShell ISE icinde calismaz (tus yakalama desteklenmiyor).' -ForegroundColor Red
        Write-Host '  Lutfen powershell.exe veya Windows Terminal icinde calistir:' -ForegroundColor Yellow
        Write-Host '    powershell.exe -ExecutionPolicy Bypass -File .\ProgramIndir.ps1' -ForegroundColor Gray
        Write-Host ''
        return
    }

    try { Initialize-Motor }
    catch {
        Write-Host ''
        Write-Host ('  Indirme motoru yuklenemedi: {0}' -f $_.Exception.Message) -ForegroundColor Red
        Write-Log 'HATA' ("Add-Type basarisiz: {0}" -f $_.Exception.ToString())
        return
    }

    $ayar = Get-Ayarlar -Yol $Ayarlar
    if ($Parcalar  -gt 0) { $ayar.parcaSayisi = $Parcalar }
    if ($EsZamanli -gt 0) { $ayar.esZamanliProgram = $EsZamanli }
    if (-not $Klasor) {
        if ($ayar.indirmeKlasoru) { $Klasor = $ayar.indirmeKlasoru }
        else { $Klasor = Join-Path $script:KokKlasor 'Indirilenler' }
    }

    [TopluIndir.Engine]::StealMinBytes = [long]$ayar.isCalmaEnAzMB * 1MB
    [TopluIndir.Engine]::MaxSplits     = [int]$ayar.isCalmaEnFazlaBolme
    [TopluIndir.Engine]::AsyncFile     = [bool]$ayar.asenkronDosya

    try { $apps = Get-Programlar -Yol $AppsJson }
    catch {
        Write-Host ''
        Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor Red
        Write-Log 'HATA' $_.Exception.Message
        return
    }

    $secim = Show-Menu -Apps $apps
    Clear-Ekran

    if (-not $secim) {
        Write-Host ''
        Write-Host '  Cikildi. Hicbir sey indirilmedi.' -ForegroundColor DarkGray
        Write-Host ''
        return
    }

    if (-not (Test-Path -LiteralPath $Klasor)) { New-Item -ItemType Directory -Path $Klasor -Force | Out-Null }
    $Klasor = (Resolve-Path -LiteralPath $Klasor).Path

    Write-Host ''
    Write-Host ('  Hazirlik — {0} program, {1} parca, {2} eszamanli' -f $secim.Count, $ayar.parcaSayisi, $ayar.esZamanliProgram) -ForegroundColor Cyan
    Write-Host ('  Hedef: {0}' -f $Klasor) -ForegroundColor DarkGray
    Write-Host ''
    Write-Log 'BILGI' ("Oturum basladi: {0} program, {1} parca, {2} eszamanli, hedef {3}" -f
        $secim.Count, $ayar.parcaSayisi, $ayar.esZamanliProgram, $Klasor)

    # Faz 1: kesif + tum sorular. Indirme basladiktan sonra soru sorulmaz.
    $isler = @()
    foreach ($i in $secim) {
        try { $isler += New-IndirmeIsi -App $apps[$i] -Hedef $Klasor }
        catch {
            $kisa = ConvertTo-SadeHata $_.Exception.Message
            Write-Host ('  {0}: HATA {1}' -f $apps[$i].ad, $kisa) -ForegroundColor Red
            Write-Log 'HATA' ("{0} hazirlik hatasi: {1}" -f $apps[$i].ad, $_.Exception.ToString())
            $is = [pscustomobject]@{
                Ad = $apps[$i].ad; App = $apps[$i]; Job = $null; Yol = ''; Host = ''
                Devam = $false; Durum = 'HATA'; Sonuc = (New-Sonuc -Ad $apps[$i].ad -Durum 'HATA' -Mesaj $kisa)
                Ornekler = $null; TepeHiz = 0.0
            }
            $isler += $is
        }
    }

    # Faz 2: DNS'i pesin coz, sonra kuyrugu calistir.
    Resolve-Dns -Hostlar @($isler | Where-Object { $_.Durum -eq 'Bekliyor' } | ForEach-Object { $_.Host })

    $kronometre = [Diagnostics.Stopwatch]::StartNew()
    $sonuclar = Start-IndirmeKuyrugu -Isler $isler -EsZamanli $ayar.esZamanliProgram `
                                     -Parcalar $ayar.parcaSayisi -Hedef $Klasor
    $kronometre.Stop()

    Show-Ozet -Sonuclar $sonuclar -Hedef $Klasor -OturumSaniye $kronometre.Elapsed.TotalSeconds
    Request-KlasorAc -Hedef $Klasor
    Write-Log 'BILGI' 'Oturum bitti.'
}

if (-not $SadeceYukle) { Start-Uygulama }
