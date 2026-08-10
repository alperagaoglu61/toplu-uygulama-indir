using System;
using System.IO;
using System.Text;
using System.Text.Json;

namespace TopluIndir.Gui.Servis
{
    // ayarlar.json konsol script ile ORTAK dosyadir: alan adlari ve degerler
    // birebir ayni kalir, GUI buraya yeni alan uydurmaz.
    public class Ayarlar
    {
        public int  ParcaSayisi         = 16;
        public int  EsZamanliProgram    = 3;
        public int  IsCalmaEnAzMB       = 8;
        public int  IsCalmaEnFazlaBolme = 3;
        public bool AsenkronDosya       = false;
        public string IndirmeKlasoru    = "";
    }

    public static class AyarServisi
    {
        public static string Yol()
        {
            string kok = AppContext.BaseDirectory;
            return Path.Combine(kok, "ayarlar.json");
        }

        public static string VarsayilanIndirmeKlasoru()
        {
            return Path.Combine(AppContext.BaseDirectory, "Indirilenler");
        }

        public static Ayarlar Oku()
        {
            Ayarlar a = new Ayarlar();
            string yol = Yol();

            try
            {
                if (File.Exists(yol))
                {
                    using (JsonDocument b = JsonDocument.Parse(File.ReadAllText(yol, Encoding.UTF8)))
                    {
                        JsonElement k = b.RootElement;
                        a.ParcaSayisi         = TamSayi(k, "parcaSayisi", a.ParcaSayisi);
                        a.EsZamanliProgram    = TamSayi(k, "esZamanliProgram", a.EsZamanliProgram);
                        a.IsCalmaEnAzMB       = TamSayi(k, "isCalmaEnAzMB", a.IsCalmaEnAzMB);
                        a.IsCalmaEnFazlaBolme = TamSayi(k, "isCalmaEnFazlaBolme", a.IsCalmaEnFazlaBolme);
                        a.AsenkronDosya       = Mantik(k, "asenkronDosya", a.AsenkronDosya);
                        a.IndirmeKlasoru      = Metin(k, "indirmeKlasoru", a.IndirmeKlasoru);
                    }
                }
            }
            catch { /* bozuk dosya: varsayilanlarla devam */ }

            if (a.ParcaSayisi < 1 || a.ParcaSayisi > 64) a.ParcaSayisi = 16;
            if (a.EsZamanliProgram < 1 || a.EsZamanliProgram > 8) a.EsZamanliProgram = 3;
            if (a.IsCalmaEnAzMB < 1) a.IsCalmaEnAzMB = 8;
            if (a.IsCalmaEnFazlaBolme < 0) a.IsCalmaEnFazlaBolme = 3;

            return a;
        }

        public static void Yaz(Ayarlar a)
        {
            // Konsol script ayni dosyayi okur: alan adlari degismez, BOM'lu UTF-8.
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("{");
            sb.AppendLine("  \"parcaSayisi\": " + a.ParcaSayisi + ",");
            sb.AppendLine("  \"esZamanliProgram\": " + a.EsZamanliProgram + ",");
            sb.AppendLine("  \"isCalmaEnAzMB\": " + a.IsCalmaEnAzMB + ",");
            sb.AppendLine("  \"isCalmaEnFazlaBolme\": " + a.IsCalmaEnFazlaBolme + ",");
            sb.AppendLine("  \"asenkronDosya\": " + (a.AsenkronDosya ? "true" : "false") + ",");
            sb.AppendLine("  \"indirmeKlasoru\": " + JsonSerializer.Serialize(a.IndirmeKlasoru ?? ""));
            sb.Append("}");

            File.WriteAllText(Yol(), sb.ToString(), new UTF8Encoding(true));
        }

        private static int TamSayi(JsonElement k, string ad, int varsayilan)
        {
            JsonElement v;
            if (k.TryGetProperty(ad, out v) && v.ValueKind == JsonValueKind.Number)
            {
                int i;
                if (v.TryGetInt32(out i)) return i;
            }
            return varsayilan;
        }

        private static bool Mantik(JsonElement k, string ad, bool varsayilan)
        {
            JsonElement v;
            if (k.TryGetProperty(ad, out v))
            {
                if (v.ValueKind == JsonValueKind.True) return true;
                if (v.ValueKind == JsonValueKind.False) return false;
            }
            return varsayilan;
        }

        private static string Metin(JsonElement k, string ad, string varsayilan)
        {
            JsonElement v;
            if (k.TryGetProperty(ad, out v) && v.ValueKind == JsonValueKind.String)
            {
                string s = v.GetString();
                if (!string.IsNullOrEmpty(s)) return s;
            }
            return varsayilan;
        }
    }
}
