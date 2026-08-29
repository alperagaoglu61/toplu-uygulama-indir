/*
    ===========================================================================
    Telif Hakki (c) 2026 Alper Ibrahimagaoglu - Tum Haklari Saklidir.
    Copyright (c) 2026 Alper Ibrahimagaoglu - All Rights Reserved.

    Bu dosya tescilli (proprietary) yazilimdir. Yalnizca kisisel ve egitim
    amacli olarak GORUNTULENEBILIR ve DEGISTIRILMEDEN calistirilabilir.

    Telif sahibinin yazili izni olmadan YASAKTIR:
      * Degistirme, uyarlama, turev eser olusturma (No Derivatives)
      * Kopyalama, yeniden dagitma, aynalama, baska bir depoda/platformda
        yayimlama (No Redistribution)
      * Ticari kullanim, satis, kiralama, alt lisanslama (No Commercial Use)
      * Bu telif basligini kaldirma veya degistirme

    Tum kosullar icin depodaki LICENSE dosyasina bakiniz.
    https://github.com/alperagaoglu61/toplu-uygulama-indir

    GARANTI YOKTUR. Yazilim internetten dosya indirir; indirilen dosyalarin
    icerigi ve guvenligi telif sahibinin sorumlulugunda degildir. Tum risk
    kullaniciya aittir.
    ===========================================================================
*/
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
        // Bazi sunucular (ornek: drivers.amd.com) Referer yoksa dosya yerine
        // hata sayfasina yonlendiriyor. apps.json > referer alanindan gelir.
        public string   Referer;
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
            return NewRequest(m, url, null);
        }

        private static HttpRequestMessage NewRequest(HttpMethod m, string url, string referer)
        {
            HttpRequestMessage r = new HttpRequestMessage(m, url);
            // HTTP/2 tek TCP uzerinden cogullar; parcali indirmede ayri TCP
            // baglantilarinin pencere buyumesini engeller. PS 5.1 ve PS 7 ayni olsun.
            r.Version = Http11;
            if (!string.IsNullOrEmpty(referer))
                r.Headers.TryAddWithoutValidation("Referer", referer);
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
            return Probe(urls, null);
        }

        public static Job Probe(string[] urls, string referer)
        {
            string son = "";
            for (int i = 0; i < urls.Length; i++)
            {
                try
                {
                    Job j = Inspect(urls[i], referer);
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
            return Inspect(url, null);
        }

        public static Job Inspect(string url, string referer)
        {
            Job j = new Job();
            j.Url = url;
            j.FinalUrl = url;
            j.Referer = referer;

            HttpResponseMessage resp = null;
            try
            {
                HttpRequestMessage req = NewRequest(HttpMethod.Get, url, referer);
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
                HttpRequestMessage req = NewRequest(HttpMethod.Head, url, referer);
                try { resp = Client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead).Result; }
                catch (Exception ex) { throw new Exception(Flatten(ex)); }
            }

            if (!resp.IsSuccessStatusCode)
            {
                resp.Dispose();
                HttpRequestMessage req = NewRequest(HttpMethod.Get, url, referer);
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
                    HttpRequestMessage req = NewRequest(HttpMethod.Get, j.FinalUrl, j.Referer);
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
            HttpRequestMessage req = NewRequest(HttpMethod.Get, j.FinalUrl, j.Referer);

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
