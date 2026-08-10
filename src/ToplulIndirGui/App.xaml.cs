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
