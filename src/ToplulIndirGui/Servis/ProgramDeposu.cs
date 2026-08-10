using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text.Json;
using TopluIndir.Gui.Model;

namespace TopluIndir.Gui.Servis
{
    // Program listesi derleme zamaninda gomulur (bkz. GUI-SPEC Bolum 6).
    // Calisma aninda disaridan apps.json okunmaz, aranmaz, yazilmaz.
    public static class ProgramDeposu
    {
        public static List<UygulamaKaydi> Yukle()
        {
            string metin;
            Assembly asm = typeof(ProgramDeposu).Assembly;

            using (Stream s = asm.GetManifestResourceStream("apps.json"))
            {
                if (s == null) throw new Exception("Gomulu program listesi bulunamadi (apps.json).");
                using (StreamReader r = new StreamReader(s)) metin = r.ReadToEnd();
            }

            List<UygulamaKaydi> liste = new List<UygulamaKaydi>();

            using (JsonDocument belge = JsonDocument.Parse(metin))
            {
                JsonElement kok = belge.RootElement;
                JsonElement dizi;
                if (!kok.TryGetProperty("programlar", out dizi))
                    throw new Exception("Program listesi bicimi hatali: 'programlar' alani yok.");

                foreach (JsonElement e in dizi.EnumerateArray())
                {
                    UygulamaKaydi k = new UygulamaKaydi();
                    k.Ad           = Metin(e, "ad");
                    k.Dosya        = Metin(e, "dosya");
                    k.Aciklama     = Metin(e, "aciklama");
                    k.Referer      = Metin(e, "referer");
                    k.Cozucu       = Metin(e, "cozucu");
                    k.Kategori     = Metin(e, "kategori");
                    k.Ikon         = Metin(e, "ikon");
                    k.Urls         = Adresler(e);
                    k.BoyutTahmini = Sayi(e, "boyutTahmini");

                    if (string.IsNullOrEmpty(k.Ad) || k.Urls.Length == 0) continue;
                    if (string.IsNullOrEmpty(k.Kategori)) k.Kategori = "araclar";
                    if (string.IsNullOrEmpty(k.Dosya)) k.Dosya = DosyaAdiTahmin(k.Urls[0]);

                    liste.Add(k);
                }
            }

            return liste;
        }

        // "url" alani tek metin veya metin dizisi olabilir (yedek link destegi).
        private static string[] Adresler(JsonElement e)
        {
            JsonElement u;
            if (!e.TryGetProperty("url", out u)) return new string[0];

            if (u.ValueKind == JsonValueKind.String)
            {
                string tek = u.GetString();
                return string.IsNullOrEmpty(tek) ? new string[0] : new string[] { tek };
            }

            if (u.ValueKind == JsonValueKind.Array)
            {
                List<string> hepsi = new List<string>();
                foreach (JsonElement x in u.EnumerateArray())
                {
                    string s = x.GetString();
                    if (!string.IsNullOrEmpty(s)) hepsi.Add(s);
                }
                return hepsi.ToArray();
            }

            return new string[0];
        }

        private static string Metin(JsonElement e, string ad)
        {
            JsonElement v;
            if (e.TryGetProperty(ad, out v) && v.ValueKind == JsonValueKind.String)
                return v.GetString();
            return "";
        }

        private static long Sayi(JsonElement e, string ad)
        {
            JsonElement v;
            if (e.TryGetProperty(ad, out v) && v.ValueKind == JsonValueKind.Number)
            {
                long l;
                if (v.TryGetInt64(out l)) return l;
            }
            return 0;
        }

        private static string DosyaAdiTahmin(string url)
        {
            try
            {
                Uri u = new Uri(url);
                string ad = Path.GetFileName(u.LocalPath);
                if (!string.IsNullOrEmpty(ad)) return ad;
            }
            catch { }
            return "indirilen.exe";
        }
    }
}
