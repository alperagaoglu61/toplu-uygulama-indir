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
using System.ComponentModel;

namespace TopluIndir.Gui.Model
{
    public enum IndirmeDurumu
    {
        Kuyrukta,
        Hazirlaniyor,
        Iniyor,
        Tamamlandi,
        Hata,
        Iptal
    }

    // Alt paneldeki tek bir indirme satiri. Motor bu satiri degil, kendi Job'ini
    // gunceller; yonetici her tik'te Job'dan okuyup buraya yansitir.
    public class IndirmeSatiri : INotifyPropertyChanged
    {
        public UygulamaKaydi Kayit { get; set; }
        public string Ad { get { return Kayit != null ? Kayit.Ad : ""; } }
        public string Yol { get; set; }

        private IndirmeDurumu _durum = IndirmeDurumu.Kuyrukta;
        public IndirmeDurumu Durum
        {
            get { return _durum; }
            set
            {
                _durum = value;
                Bildir("Durum"); Bildir("DurumMetni"); Bildir("Bitti");
                Bildir("HataVar"); Bildir("Basarili");
            }
        }

        public bool Bitti
        {
            get
            {
                return _durum == IndirmeDurumu.Tamamlandi || _durum == IndirmeDurumu.Hata
                    || _durum == IndirmeDurumu.Iptal;
            }
        }
        public bool HataVar { get { return _durum == IndirmeDurumu.Hata; } }
        public bool Basarili { get { return _durum == IndirmeDurumu.Tamamlandi; } }

        private double _yuzde;
        public double Yuzde
        {
            get { return _yuzde; }
            set { _yuzde = value; Bildir("Yuzde"); Bildir("YuzdeMetni"); }
        }
        public string YuzdeMetni { get { return ((int)Math.Round(_yuzde)) + "%"; } }

        private double _hiz;
        public double Hiz
        {
            get { return _hiz; }
            set { _hiz = value; Bildir("Hiz"); Bildir("HizMetni"); }
        }
        public string HizMetni { get { return Bicim.Hiz(_hiz); } }

        private long _inen;
        public long Inen
        {
            get { return _inen; }
            set { _inen = value; Bildir("Inen"); Bildir("BoyutMetni"); }
        }

        private long _toplam;
        public long Toplam
        {
            get { return _toplam; }
            set { _toplam = value; Bildir("Toplam"); Bildir("BoyutMetni"); }
        }

        public string BoyutMetni
        {
            get
            {
                if (_toplam <= 0) return Bicim.Boyut(_inen);
                return Bicim.Boyut(_inen) + " / " + Bicim.Boyut(_toplam);
            }
        }

        private string _mesaj = "";
        public string Mesaj
        {
            get { return _mesaj; }
            set { _mesaj = value; Bildir("Mesaj"); Bildir("DurumMetni"); }
        }

        public string DurumMetni
        {
            get
            {
                switch (_durum)
                {
                    case IndirmeDurumu.Kuyrukta:     return "Kuyrukta";
                    case IndirmeDurumu.Hazirlaniyor: return "Hazırlanıyor";
                    case IndirmeDurumu.Iniyor:       return "İniyor";
                    case IndirmeDurumu.Tamamlandi:   return "Tamamlandı";
                    case IndirmeDurumu.Iptal:        return "İptal edildi";
                    default:                         return string.IsNullOrEmpty(_mesaj) ? "Hata" : _mesaj;
                }
            }
        }

        public event PropertyChangedEventHandler PropertyChanged;
        private void Bildir(string ad)
        {
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(ad));
        }
    }
}
