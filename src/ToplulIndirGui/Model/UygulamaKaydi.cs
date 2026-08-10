using System;
using System.ComponentModel;

namespace TopluIndir.Gui.Model
{
    // apps.json'daki tek bir program kaydi. Secim durumu kategoriler arasi
    // gezinirken korunur, bu yuzden model degisiklik bildirir.
    public class UygulamaKaydi : INotifyPropertyChanged
    {
        public string Ad { get; set; }
        public string[] Urls { get; set; }
        public string Dosya { get; set; }
        public string Aciklama { get; set; }
        public string Referer { get; set; }
        public string Cozucu { get; set; }
        public string Kategori { get; set; }
        public string Ikon { get; set; }
        public long BoyutTahmini { get; set; }   // bayt, 0 = bilinmiyor

        private bool _secili;
        public bool Secili
        {
            get { return _secili; }
            set
            {
                if (_secili == value) return;
                _secili = value;
                Bildir("Secili");
            }
        }

        // Marka ikonu yoksa harf kutucugu kullanilir.
        public bool IkonVar { get { return !string.IsNullOrEmpty(Ikon); } }
        public string Harf
        {
            get
            {
                if (string.IsNullOrEmpty(Ad)) return "?";
                foreach (char c in Ad)
                {
                    if (char.IsLetterOrDigit(c)) return char.ToUpperInvariant(c).ToString();
                }
                return Ad.Substring(0, 1).ToUpperInvariant();
            }
        }

        public string BoyutMetni
        {
            get
            {
                if (BoyutTahmini <= 0) return "";
                return Bicim.Boyut(BoyutTahmini);
            }
        }

        public event PropertyChangedEventHandler PropertyChanged;
        private void Bildir(string ad)
        {
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(ad));
        }
    }

    public static class Bicim
    {
        public static string Boyut(long bayt)
        {
            if (bayt <= 0) return "—";
            double b = bayt;
            if (b >= 1073741824) return (b / 1073741824).ToString("0.#") + " GB";
            if (b >= 1048576) return (b / 1048576).ToString("0.#") + " MB";
            if (b >= 1024) return (b / 1024).ToString("0.#") + " KB";
            return bayt + " B";
        }

        public static string Hiz(double baytSaniye)
        {
            if (baytSaniye <= 0) return "—";
            return Boyut((long)baytSaniye) + "/s";
        }
    }
}
