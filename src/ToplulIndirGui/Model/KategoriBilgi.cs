using System;
using System.Collections.Generic;
using System.ComponentModel;

namespace TopluIndir.Gui.Model
{
    // Kategori sayisi 7 ile sabit. Yeni program once bu 7 taneden birine sigdirilir;
    // yeni kategori ancak en az 5 program birikirse acilir (bkz. GUI-SPEC Bolum 3).
    public class KategoriBilgi : INotifyPropertyChanged
    {
        public string Anahtar { get; set; }
        public string Etiket { get; set; }
        public string IkonAnahtari { get { return "ikon.kat." + Anahtar; } }

        private int _sayi;
        public int Sayi
        {
            get { return _sayi; }
            set { _sayi = value; Bildir("Sayi"); }
        }

        private int _seciliSayi;
        public int SeciliSayi
        {
            get { return _seciliSayi; }
            set { _seciliSayi = value; Bildir("SeciliSayi"); Bildir("SecimVar"); }
        }

        public bool SecimVar { get { return _seciliSayi > 0; } }

        private bool _aktif;
        public bool Aktif
        {
            get { return _aktif; }
            set { _aktif = value; Bildir("Aktif"); }
        }

        // Gorunen Turkce etiketler tek yerden yonetilir.
        public static readonly string[] Sira = new string[]
        {
            "tarayici", "oyun", "iletisim", "medya", "gelistirici", "araclar", "redistributable"
        };

        private static readonly Dictionary<string, string> Etiketler = new Dictionary<string, string>
        {
            { "tarayici",        "Tarayıcı" },
            { "oyun",            "Oyun" },
            { "iletisim",        "İletişim" },
            { "medya",           "Medya" },
            { "gelistirici",     "Geliştirici" },
            { "araclar",         "Araçlar" },
            { "redistributable", "Sürücü / Redist." }
        };

        public static string EtiketAl(string anahtar)
        {
            string s;
            if (Etiketler.TryGetValue(anahtar, out s)) return s;
            return anahtar;
        }

        public event PropertyChangedEventHandler PropertyChanged;
        private void Bildir(string ad)
        {
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(ad));
        }
    }
}
