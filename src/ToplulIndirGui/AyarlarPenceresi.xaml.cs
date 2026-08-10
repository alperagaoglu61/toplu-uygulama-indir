using System;
using System.Windows;
using System.Windows.Input;
using TopluIndir.Gui.Servis;

namespace TopluIndir.Gui
{
    // Sadece indirme davranisi ayarlanir. Program listesi burada duzenlenmez -
    // liste derleme zamaninda gomulur (GUI-SPEC Bolum 6).
    public partial class AyarlarPenceresi : Window
    {
        public AyarlarPenceresi()
        {
            InitializeComponent();

            Ayarlar a = AyarServisi.Oku();
            txtParca.Text = a.ParcaSayisi.ToString();
            txtEsZamanli.Text = a.EsZamanliProgram.ToString();
            txtKlasor.Text = string.IsNullOrEmpty(a.IndirmeKlasoru)
                ? AyarServisi.VarsayilanIndirmeKlasoru()
                : a.IndirmeKlasoru;
        }

        private void Kaydet_Tik(object gonderen, RoutedEventArgs e)
        {
            Ayarlar a = AyarServisi.Oku();

            int parca;
            if (!int.TryParse(txtParca.Text.Trim(), out parca) || parca < 1 || parca > 64)
            {
                MessageBox.Show(this, "Parça sayısı 1-64 arası olmalı.", "Ayarlar",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            int esZamanli;
            if (!int.TryParse(txtEsZamanli.Text.Trim(), out esZamanli) || esZamanli < 1 || esZamanli > 8)
            {
                MessageBox.Show(this, "Eşzamanlı program sayısı 1-8 arası olmalı.", "Ayarlar",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            a.ParcaSayisi = parca;
            a.EsZamanliProgram = esZamanli;

            string klasor = txtKlasor.Text.Trim();
            a.IndirmeKlasoru = string.Equals(klasor, AyarServisi.VarsayilanIndirmeKlasoru(),
                StringComparison.OrdinalIgnoreCase) ? "" : klasor;

            try { AyarServisi.Yaz(a); }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Ayarlar kaydedilemedi:\r\n" + ex.Message, "Ayarlar",
                    MessageBoxButton.OK, MessageBoxImage.Error);
                return;
            }

            DialogResult = true;
            Close();
        }

        private void Gozat_Tik(object gonderen, RoutedEventArgs e)
        {
            Microsoft.Win32.OpenFolderDialog d = new Microsoft.Win32.OpenFolderDialog();
            d.Title = "İndirme klasörü seç";
            try { d.InitialDirectory = txtKlasor.Text.Trim(); } catch { }
            if (d.ShowDialog(this) == true) txtKlasor.Text = d.FolderName;
        }

        private void Kapat_Tik(object gonderen, RoutedEventArgs e) { Close(); }

        private void Baslik_Surukle(object gonderen, MouseButtonEventArgs e)
        {
            if (e.ButtonState == MouseButtonState.Pressed) DragMove();
        }
    }
}
