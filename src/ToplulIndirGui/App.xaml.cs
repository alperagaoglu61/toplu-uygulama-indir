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
using System.Windows;
using System.Windows.Threading;

namespace TopluIndir.Gui
{
    public partial class App : Application
    {
        protected override void OnStartup(StartupEventArgs e)
        {
            // Yakalanmamis hata pencereyi sessizce kapatmasin: kullaniciya soyle.
            DispatcherUnhandledException += delegate (object s, DispatcherUnhandledExceptionEventArgs a)
            {
                MessageBox.Show(
                    "Beklenmeyen hata:\r\n\r\n" + a.Exception.Message,
                    "Toplu Program Indir", MessageBoxButton.OK, MessageBoxImage.Error);
                a.Handled = true;
            };

            AppDomain.CurrentDomain.UnhandledException += delegate (object s, UnhandledExceptionEventArgs a)
            {
                Exception ex = a.ExceptionObject as Exception;
                if (ex == null) return;
                MessageBox.Show(
                    "Beklenmeyen hata:\r\n\r\n" + ex.Message,
                    "Toplu Program Indir", MessageBoxButton.OK, MessageBoxImage.Error);
            };

            base.OnStartup(e);
        }
    }
}
