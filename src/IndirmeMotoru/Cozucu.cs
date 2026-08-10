using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;

namespace TopluIndir
{
    // Bazi siteler dosyayi sabit bir adreste tutmaz: indirme sayfasindan gecici
    // imzali link uretilir. Bu tur kayitlar apps.json'da "cozucu" alani ile
    // isaretlenir, "url" alani indirme sayfasini gosterir; gercek link burada
    // indirme aninda cozulur.
    public static class Cozucu
    {
        public static string TarayiciUA =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";

        // Bilinen cozucu adini calistirir. Bilinmeyen ad gelirse url oldugu gibi kalir.
        public static string[] Coz(string cozucu, string[] urls)
        {
            if (string.IsNullOrEmpty(cozucu)) return urls;
            if (urls == null || urls.Length == 0) throw new Exception("Cozulecek adres yok");

            switch (cozucu.Trim().ToLowerInvariant())
            {
                case "techpowerup":
                    return new string[] { TechPowerUp(urls[0]) };
                default:
                    return urls;
            }
        }

        public static string TechPowerUp(string sayfaUrl)
        {
            CookieContainer kavanoz = new CookieContainer();

            using (HttpClientHandler h = new HttpClientHandler())
            {
                h.CookieContainer = kavanoz;
                h.UseCookies = true;
                h.AllowAutoRedirect = false;
                try { h.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate; } catch { }

                using (HttpClient c = new HttpClient(h))
                {
                    c.Timeout = TimeSpan.FromSeconds(60);
                    c.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", TarayiciUA);

                    // 1. Indirme sayfasi: en ustteki gizli id en yeni surumdur.
                    string sayfa = Getir(c, HttpMethod.Get, sayfaUrl, null, null);
                    Match m = Regex.Match(sayfa, "name=\"id\"\\s+value=\"(\\d+)\"");
                    if (!m.Success) throw new Exception("TechPowerUp: surum kimligi bulunamadi");
                    string id = m.Groups[1].Value;

                    // 2. id gonderilince ayna listesi gelir, ilki en yakin sunucudur.
                    Dictionary<string, string> alan1 = new Dictionary<string, string>();
                    alan1["id"] = id;
                    string aynalar = Getir(c, HttpMethod.Post, sayfaUrl, alan1, sayfaUrl);
                    Match m2 = Regex.Match(aynalar, "name=\"server_id\"\\s+value=\"(\\d+)\"");
                    if (!m2.Success) throw new Exception("TechPowerUp: ayna sunucu bulunamadi");
                    string sunucu = m2.Groups[1].Value;

                    // 3. Sunucu secimi 302 ile imzali linke yonlendirir. Yonlendirme
                    //    izlenmez, Location alinir; indirmeyi motor kendisi baslatir.
                    Dictionary<string, string> alan2 = new Dictionary<string, string>();
                    alan2["id"] = id;
                    alan2["server_id"] = sunucu;

                    using (HttpRequestMessage req = Istek(HttpMethod.Post, sayfaUrl, alan2, sayfaUrl))
                    using (HttpResponseMessage resp = c.SendAsync(req).Result)
                    {
                        int kod = (int)resp.StatusCode;
                        if (kod >= 300 && kod < 400 && resp.Headers.Location != null)
                        {
                            Uri hedef = resp.Headers.Location;
                            if (!hedef.IsAbsoluteUri) hedef = new Uri(new Uri(sayfaUrl), hedef);
                            return hedef.AbsoluteUri;
                        }

                        string govde = resp.Content.ReadAsStringAsync().Result;
                        Match m3 = Regex.Match(govde, "https?://[^\"'<>\\s]+\\.(exe|msi|zip)");
                        if (m3.Success) return m3.Value;
                    }

                    throw new Exception("TechPowerUp: indirme linki alinamadi");
                }
            }
        }

        private static HttpRequestMessage Istek(HttpMethod m, string url,
            Dictionary<string, string> alanlar, string referer)
        {
            HttpRequestMessage r = new HttpRequestMessage(m, url);
            if (!string.IsNullOrEmpty(referer)) r.Headers.TryAddWithoutValidation("Referer", referer);
            if (alanlar != null) r.Content = new FormUrlEncodedContent(alanlar);
            return r;
        }

        // GET/POST gonderir, yonlendirmeleri elle izler (en fazla 5 adim).
        private static string Getir(HttpClient c, HttpMethod m, string url,
            Dictionary<string, string> alanlar, string referer)
        {
            string suanki = url;
            HttpMethod yontem = m;

            for (int adim = 0; adim < 6; adim++)
            {
                using (HttpRequestMessage req = Istek(yontem, suanki, alanlar, referer))
                using (HttpResponseMessage resp = c.SendAsync(req).Result)
                {
                    int kod = (int)resp.StatusCode;
                    if (kod >= 300 && kod < 400 && resp.Headers.Location != null)
                    {
                        Uri hedef = resp.Headers.Location;
                        if (!hedef.IsAbsoluteUri) hedef = new Uri(new Uri(suanki), hedef);
                        suanki = hedef.AbsoluteUri;
                        yontem = HttpMethod.Get;   // yonlendirme sonrasi govde tasinmaz
                        alanlar = null;
                        continue;
                    }

                    if (!resp.IsSuccessStatusCode)
                        throw new Exception("TechPowerUp: sayfa HTTP " + kod + " dondu");

                    return resp.Content.ReadAsStringAsync().Result;
                }
            }

            throw new Exception("TechPowerUp: cok fazla yonlendirme");
        }
    }
}
