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
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using TopluIndir.Gui.Model;
using TopluIndir.Gui.Servis;

namespace TopluIndir.Gui
{
    public partial class AnaPencere : Window
    {
        private readonly List<UygulamaKaydi> _hepsi;
        private readonly ObservableCollection<KategoriBilgi> _kategoriler = new ObservableCollection<KategoriBilgi>();
        private readonly ObservableCollection<UygulamaKaydi> _gorunen = new ObservableCollection<UygulamaKaydi>();
        private readonly ObservableCollection<UygulamaKaydi> _aramaSonucu = new ObservableCollection<UygulamaKaydi>();
        private readonly IndirmeYoneticisi _yonetici = new IndirmeYoneticisi();

        private KategoriBilgi _aktifKategori;
        private bool _listeEkraninda;

        public AnaPencere()
        {
            InitializeComponent();

            _hepsi = ProgramDeposu.Yukle();
            foreach (UygulamaKaydi k in _hepsi) k.PropertyChanged += Kayit_Degisti;

            KategorileriKur();

            listeKategoriKart.ItemsSource = _kategoriler;
            listeKategoriYan.ItemsSource  = _kategoriler;
            listeProgram.ItemsSource      = _gorunen;
            listeArama1.ItemsSource       = _aramaSonucu;
            listeIndirme.ItemsSource      = _yonetici.Satirlar;

            txtSayi.Text = "· " + _hepsi.Count + " program";

            _yonetici.Degisti += delegate { DurumTazele(); };
            _yonetici.SatirBitti += Satir_Bitti;

            Loaded += delegate { YarimKontrol(); DurumTazele(); };
            Closing += Pencere_Kapaniyor;
        }

        // ---------------------------------------------------------------- kategori

        private void KategorileriKur()
        {
            foreach (string anahtar in KategoriBilgi.Sira)
            {
                int sayi = _hepsi.Count(x => x.Kategori == anahtar);
                if (sayi == 0) continue;

                KategoriBilgi k = new KategoriBilgi();
                k.Anahtar = anahtar;
                k.Etiket = KategoriBilgi.EtiketAl(anahtar);
                k.Sayi = sayi;
                _kategoriler.Add(k);
            }
        }

        private void KategoriSec(KategoriBilgi k)
        {
            if (k == null) return;

            foreach (KategoriBilgi x in _kategoriler) x.Aktif = (x == k);
            _aktifKategori = k;

            EkranDegistir(true);
            ListeTazele();
        }

        private void EkranDegistir(bool listeEkrani)
        {
            _listeEkraninda = listeEkrani;
            ekranKategori.Visibility = listeEkrani ? Visibility.Collapsed : Visibility.Visible;
            ekranListe.Visibility    = listeEkrani ? Visibility.Visible : Visibility.Collapsed;
            btnGeri.Visibility       = listeEkrani ? Visibility.Visible : Visibility.Collapsed;
        }

        // Arama ve kategori filtresi birlikte (AND) calisir.
        private void ListeTazele()
        {
            string ara = (txtAra2.Text ?? "").Trim();
            _gorunen.Clear();

            IEnumerable<UygulamaKaydi> kaynak = _hepsi;
            if (_aktifKategori != null) kaynak = kaynak.Where(x => x.Kategori == _aktifKategori.Anahtar);
            if (ara.Length > 0) kaynak = kaynak.Where(x => Eslesir(x, ara));

            foreach (UygulamaKaydi k in kaynak) _gorunen.Add(k);
            TumunuSecMetni();
        }

        private void AramaTazele1()
        {
            string ara = (txtAra1.Text ?? "").Trim();
            _aramaSonucu.Clear();

            if (ara.Length == 0)
            {
                pnlArama1.Visibility = Visibility.Collapsed;
                listeKategoriKart.Visibility = Visibility.Visible;
                return;
            }

            // Arama sirasinda kategori ayrimi kalkar: duz sonuc listesi.
            foreach (UygulamaKaydi k in _hepsi.Where(x => Eslesir(x, ara))) _aramaSonucu.Add(k);
            pnlArama1.Visibility = Visibility.Visible;
            listeKategoriKart.Visibility = Visibility.Collapsed;
        }

        private static bool Eslesir(UygulamaKaydi k, string ara)
        {
            StringComparison c = StringComparison.OrdinalIgnoreCase;
            if (!string.IsNullOrEmpty(k.Ad) && k.Ad.IndexOf(ara, c) >= 0) return true;
            if (!string.IsNullOrEmpty(k.Aciklama) && k.Aciklama.IndexOf(ara, c) >= 0) return true;
            return false;
        }

        // ---------------------------------------------------------------- olaylar

        private void Kart_Tik(object gonderen, MouseButtonEventArgs e)
        {
            FrameworkElement fe = gonderen as FrameworkElement;
            if (fe == null) return;
            KategoriSec(fe.DataContext as KategoriBilgi);
        }

        private void Kategori_Tik(object gonderen, MouseButtonEventArgs e)
        {
            FrameworkElement fe = gonderen as FrameworkElement;
            if (fe == null) return;
            KategoriSec(fe.DataContext as KategoriBilgi);
        }

        // Satira tiklamak checkbox'i toggle eder.
        private void Program_Tik(object gonderen, MouseButtonEventArgs e)
        {
            FrameworkElement fe = gonderen as FrameworkElement;
            if (fe == null) return;
            UygulamaKaydi k = fe.DataContext as UygulamaKaydi;
            if (k == null) return;
            k.Secili = !k.Secili;
        }

        private void Ara_Degisti(object gonderen, TextChangedEventArgs e)
        {
            if (gonderen == txtAra1) AramaTazele1();
            else ListeTazele();
        }

        private void Geri_Tik(object gonderen, RoutedEventArgs e)
        {
            foreach (KategoriBilgi x in _kategoriler) x.Aktif = false;
            _aktifKategori = null;
            EkranDegistir(false);
        }

        private void TumunuSec_Tik(object gonderen, RoutedEventArgs e)
        {
            // O an listede gorunenleri sec / kaldir (kategori kavrami degil, gorunum eylemi).
            bool hepsiSecili = _gorunen.Count > 0 && _gorunen.All(x => x.Secili);
            foreach (UygulamaKaydi k in _gorunen) k.Secili = !hepsiSecili;
            TumunuSecMetni();
        }

        private void TumunuSecMetni()
        {
            bool hepsiSecili = _gorunen.Count > 0 && _gorunen.All(x => x.Secili);
            btnTumunuSec.Content = hepsiSecili ? "Seçimi kaldır" : "Tümünü seç";
        }

        private void Kayit_Degisti(object gonderen, System.ComponentModel.PropertyChangedEventArgs e)
        {
            if (e.PropertyName != "Secili") return;
            TumunuSecMetni();
            DurumTazele();
        }

        private void Indir_Tik(object gonderen, RoutedEventArgs e)
        {
            List<UygulamaKaydi> secili = _hepsi.Where(x => x.Secili).ToList();
            if (secili.Count == 0)
            {
                MessageBox.Show(this, "En az bir program seç.", "Toplu Program İndir",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            _yonetici.Kuyruğa(secili);
            foreach (UygulamaKaydi k in secili) k.Secili = false;

            pnlIndirme.Visibility = Visibility.Visible;
            DurumTazele();
        }

        private void KlasorAc_Tik(object gonderen, RoutedEventArgs e)
        {
            string klasor = _yonetici.HedefKlasor;
            try
            {
                if (!Directory.Exists(klasor)) Directory.CreateDirectory(klasor);
                ProcessStartInfo psi = new ProcessStartInfo(klasor);
                psi.UseShellExecute = true;
                Process.Start(psi);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Klasör açılamadı:\r\n" + ex.Message, "Toplu Program İndir",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private void LinkKopyala_Tik(object gonderen, RoutedEventArgs e)
        {
            UygulamaKaydi k = MenuKaydi(gonderen);
            if (k == null || k.Urls.Length == 0) return;
            try { Clipboard.SetText(string.Join(Environment.NewLine, k.Urls)); }
            catch { /* pano baska uygulamada kilitli olabilir */ }
        }

        private static UygulamaKaydi MenuKaydi(object gonderen)
        {
            MenuItem mi = gonderen as MenuItem;
            if (mi == null) return null;
            ContextMenu cm = mi.Parent as ContextMenu;
            if (cm == null) return null;
            FrameworkElement sahip = cm.PlacementTarget as FrameworkElement;
            if (sahip == null) return null;
            return sahip.DataContext as UygulamaKaydi;
        }

        private void Ayarlar_Tik(object gonderen, RoutedEventArgs e)
        {
            AyarlarPenceresi p = new AyarlarPenceresi();
            p.Owner = this;
            if (p.ShowDialog() == true) _yonetici.Ayar = AyarServisi.Oku();
        }

        // ---------------------------------------------------------------- indirme durumu

        private void Satir_Bitti(object gonderen, IndirmeSatiri satir)
        {
            if (satir.Durum != IndirmeDurumu.Tamamlandi) return;

            // Basarili satir kisa sure parlar, sonra listeden duser.
            DispatcherTimer t = new DispatcherTimer();
            t.Interval = TimeSpan.FromSeconds(2.5);
            t.Tick += delegate
            {
                t.Stop();
                _yonetici.Satirlar.Remove(satir);
                DurumTazele();
            };
            t.Start();
        }

        private void DurumTazele()
        {
            int seciliSayi = 0;
            long seciliBoyut = 0;
            foreach (UygulamaKaydi k in _hepsi)
            {
                if (!k.Secili) continue;
                seciliSayi++;
                seciliBoyut += k.BoyutTahmini;
            }

            foreach (KategoriBilgi kat in _kategoriler)
                kat.SeciliSayi = _hepsi.Count(x => x.Kategori == kat.Anahtar && x.Secili);

            string boyut = seciliBoyut > 0 ? " · " + Bicim.Boyut(seciliBoyut) : "";
            txtSecim.Text = seciliSayi > 0 ? seciliSayi + " seçili" + boyut : "seçim yok";

            int aktif = _yonetici.AktifSayi;
            int kuyruk = _yonetici.KuyrukSayi;
            if (aktif > 0 || kuyruk > 0)
            {
                txtDurum.Text = "Toplam " + Bicim.Hiz(_yonetici.ToplamHiz) +
                                " · " + aktif + " aktif, " + kuyruk + " kuyrukta";
                btnIndir.Content = "İndiriliyor...";
            }
            else
            {
                txtDurum.Text = "Hedef: " + _yonetici.HedefKlasor;
                btnIndir.Content = "İndir";
            }

            btnIndir.Opacity = seciliSayi > 0 ? 1.0 : 0.55;
            pnlIndirme.Visibility = _yonetici.Satirlar.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        // ---------------------------------------------------------------- yarim indirme

        private void YarimKontrol()
        {
            List<string> yarim = _yonetici.YarimDosyalar();
            if (yarim.Count == 0) { pnlYarim.Visibility = Visibility.Collapsed; return; }

            txtYarim.Text = yarim.Count + " yarım indirme bulundu — devam edilsin mi?";
            pnlYarim.Visibility = Visibility.Visible;
        }

        private void YarimDevam_Tik(object gonderen, RoutedEventArgs e)
        {
            // Yarim dosya adindan kaydi bul, kuyruga at: motor kaldigi yerden devam eder.
            List<UygulamaKaydi> devam = new List<UygulamaKaydi>();
            foreach (string d in _yonetici.YarimDosyalar())
            {
                string dosya = Path.GetFileName(d);
                if (dosya.EndsWith(".indiriliyor", StringComparison.OrdinalIgnoreCase))
                    dosya = dosya.Substring(0, dosya.Length - ".indiriliyor".Length);

                UygulamaKaydi k = _hepsi.FirstOrDefault(x =>
                    string.Equals(x.Dosya, dosya, StringComparison.OrdinalIgnoreCase));
                if (k != null && !devam.Contains(k)) devam.Add(k);
            }

            pnlYarim.Visibility = Visibility.Collapsed;
            if (devam.Count == 0) return;

            _yonetici.Kuyruğa(devam);
            pnlIndirme.Visibility = Visibility.Visible;
            DurumTazele();
        }

        private void YarimYoksay_Tik(object gonderen, RoutedEventArgs e)
        {
            _yonetici.YarimlariSil();
            pnlYarim.Visibility = Visibility.Collapsed;
        }

        // ---------------------------------------------------------------- pencere

        private void Baslik_Surukle(object gonderen, MouseButtonEventArgs e)
        {
            if (e.ClickCount == 2) { Buyut_Tik(gonderen, null); return; }
            if (e.ButtonState == MouseButtonState.Pressed) DragMove();
        }

        private void Kucult_Tik(object gonderen, RoutedEventArgs e) { WindowState = WindowState.Minimized; }

        private void Buyut_Tik(object gonderen, RoutedEventArgs e)
        {
            WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
        }

        private void Kapat_Tik(object gonderen, RoutedEventArgs e) { Close(); }

        private void Pencere_Kapaniyor(object gonderen, System.ComponentModel.CancelEventArgs e)
        {
            if (!_yonetici.CalisiyorMu) return;

            MessageBoxResult c = MessageBox.Show(this,
                "İndirme sürüyor, kapatılsın mı?\r\n\r\nYarım dosyalar diskte kalır, " +
                "uygulama tekrar açıldığında devam ettirilebilir.",
                "Toplu Program İndir", MessageBoxButton.YesNo, MessageBoxImage.Question);

            if (c != MessageBoxResult.Yes) { e.Cancel = true; return; }
            _yonetici.HepsiniIptalEt();
        }
    }
}
