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
using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;

namespace TopluIndir.Gui.Donusturucu
{
    // Marka slug'i -> Ikonlar.xaml icindeki Geometry. Bulunamazsa null (harf kutucugu devreye girer).
    public class IkonGeometri : IValueConverter
    {
        public object Convert(object v, Type t, object p, CultureInfo c)
        {
            string slug = v as string;
            if (string.IsNullOrEmpty(slug)) return null;
            object g = Application.Current.TryFindResource("ikon." + slug);
            return g as Geometry;
        }
        public object ConvertBack(object v, Type t, object p, CultureInfo c) { throw new NotSupportedException(); }
    }

    // Marka slug'i -> markanin resmi rengi. Marka ikonlari tek tona cevrilmez.
    public class IkonRenk : IValueConverter
    {
        public object Convert(object v, Type t, object p, CultureInfo c)
        {
            string slug = v as string;
            if (!string.IsNullOrEmpty(slug))
            {
                object f = Application.Current.TryFindResource("renk." + slug);
                if (f != null) return f;
            }
            return Application.Current.TryFindResource("IkonPasif");
        }
        public object ConvertBack(object v, Type t, object p, CultureInfo c) { throw new NotSupportedException(); }
    }

    // Kategori anahtari -> arayuz ikonu (gri tonda, marka degil)
    public class KategoriIkonu : IValueConverter
    {
        public object Convert(object v, Type t, object p, CultureInfo c)
        {
            string anahtar = v as string;
            if (string.IsNullOrEmpty(anahtar)) return null;
            return Application.Current.TryFindResource(anahtar) as Geometry;
        }
        public object ConvertBack(object v, Type t, object p, CultureInfo c) { throw new NotSupportedException(); }
    }

    public class BoolGorunur : IValueConverter
    {
        public object Convert(object v, Type t, object p, CultureInfo c)
        {
            bool b = v is bool && (bool)v;
            if (p != null && p.ToString() == "ters") b = !b;
            return b ? Visibility.Visible : Visibility.Collapsed;
        }
        public object ConvertBack(object v, Type t, object p, CultureInfo c) { throw new NotSupportedException(); }
    }

    public class MetinVarGorunur : IValueConverter
    {
        public object Convert(object v, Type t, object p, CultureInfo c)
        {
            string s = v as string;
            bool var_ = !string.IsNullOrEmpty(s);
            if (p != null && p.ToString() == "ters") var_ = !var_;
            return var_ ? Visibility.Visible : Visibility.Collapsed;
        }
        public object ConvertBack(object v, Type t, object p, CultureInfo c) { throw new NotSupportedException(); }
    }

    // Ilerleme yuzdesi -> piksel genisligi (ilerleme cubugu dolgusu icin)
    public class YuzdeGenislik : IMultiValueConverter
    {
        public object Convert(object[] v, Type t, object p, CultureInfo c)
        {
            if (v.Length < 2) return 0.0;
            double yuzde = v[0] is double ? (double)v[0] : 0;
            double genislik = v[1] is double ? (double)v[1] : 0;
            if (double.IsNaN(genislik) || genislik <= 0) return 0.0;
            double d = genislik * Math.Max(0, Math.Min(100, yuzde)) / 100.0;
            return d;
        }
        public object[] ConvertBack(object v, Type[] t, object p, CultureInfo c) { throw new NotSupportedException(); }
    }
}
