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
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;
using TopluIndir.Gui.Model;

namespace TopluIndir.Gui.Servis
{
    // Indirme mantigi burada YAZILMAZ: TopluIndir.Engine cagrilir. Bu sinif sadece
    // kuyruk, ilerleme ornekleme ve dogrulama sarmalayicisidir - konsol scriptteki
    // Start-IndirmeKuyrugu ile ayni akis.
    public class IndirmeYoneticisi
    {
        private readonly ObservableCollection<IndirmeSatiri> _satirlar =
            new ObservableCollection<IndirmeSatiri>();
        public ObservableCollection<IndirmeSatiri> Satirlar { get { return _satirlar; } }

        private readonly Dictionary<IndirmeSatiri, Job> _isler = new Dictionary<IndirmeSatiri, Job>();
        private readonly Dictionary<IndirmeSatiri, Ornek> _ornekler = new Dictionary<IndirmeSatiri, Ornek>();
        private readonly Queue<IndirmeSatiri> _kuyruk = new Queue<IndirmeSatiri>();

        private readonly DispatcherTimer _saat;
        private Ayarlar _ayar;
        private string _hedefKlasor;

        public event EventHandler Degisti;
        public event EventHandler<IndirmeSatiri> SatirBitti;

        private class Ornek
        {
            public DateTime Zaman;
            public long Bayt;
            public double SonHiz;
        }

        public IndirmeYoneticisi()
        {
            _ayar = AyarServisi.Oku();
            _hedefKlasor = HedefKlasorBul(_ayar);

            _saat = new DispatcherTimer();
            _saat.Interval = TimeSpan.FromMilliseconds(250);
            _saat.Tick += delegate { Tik(); };
        }

        public string HedefKlasor { get { return _hedefKlasor; } }

        public Ayarlar Ayar
        {
            get { return _ayar; }
            set
            {
                _ayar = value;
                _hedefKlasor = HedefKlasorBul(_ayar);
                MotorAyarlariniUygula();
            }
        }

        public int AktifSayi
        {
            get
            {
                int n = 0;
                foreach (IndirmeSatiri s in _satirlar)
                    if (s.Durum == IndirmeDurumu.Iniyor || s.Durum == IndirmeDurumu.Hazirlaniyor) n++;
                return n;
            }
        }

        public int KuyrukSayi { get { return _kuyruk.Count; } }

        public bool CalisiyorMu { get { return AktifSayi > 0 || _kuyruk.Count > 0; } }

        public double ToplamHiz
        {
            get
            {
                double t = 0;
                foreach (IndirmeSatiri s in _satirlar)
                    if (s.Durum == IndirmeDurumu.Iniyor) t += s.Hiz;
                return t;
            }
        }

        private static string HedefKlasorBul(Ayarlar a)
        {
            if (!string.IsNullOrEmpty(a.IndirmeKlasoru)) return a.IndirmeKlasoru;
            return AyarServisi.VarsayilanIndirmeKlasoru();
        }

        private void MotorAyarlariniUygula()
        {
            Engine.StealMinBytes = (long)_ayar.IsCalmaEnAzMB * 1048576L;
            Engine.MaxSplits     = _ayar.IsCalmaEnFazlaBolme;
            Engine.AsyncFile     = _ayar.AsenkronDosya;
        }

        // Secilen programlari kuyruga ekler. Indirme sururken tekrar cagrilabilir;
        // yeni kayitlar mevcut kuyruga eklenir, calisanlar iptal edilmez.
        public void Kuyruğa(IEnumerable<UygulamaKaydi> kayitlar)
        {
            MotorAyarlariniUygula();

            foreach (UygulamaKaydi k in kayitlar)
            {
                bool zatenVar = false;
                foreach (IndirmeSatiri s in _satirlar)
                {
                    if (s.Kayit == k && !s.Bitti) { zatenVar = true; break; }
                }
                if (zatenVar) continue;

                IndirmeSatiri satir = new IndirmeSatiri();
                satir.Kayit = k;
                satir.Durum = IndirmeDurumu.Kuyrukta;
                satir.Toplam = k.BoyutTahmini;

                _satirlar.Add(satir);
                _kuyruk.Enqueue(satir);
            }

            if (!_saat.IsEnabled) _saat.Start();
            KuyruguBesle();
            Bildir();
        }

        private void KuyruguBesle()
        {
            while (AktifSayi < _ayar.EsZamanliProgram && _kuyruk.Count > 0)
            {
                IndirmeSatiri satir = _kuyruk.Dequeue();
                if (satir.Durum != IndirmeDurumu.Kuyrukta) continue;
                Baslat(satir);
            }
        }

        private void Baslat(IndirmeSatiri satir)
        {
            satir.Durum = IndirmeDurumu.Hazirlaniyor;

            UygulamaKaydi k = satir.Kayit;
            int parca = _ayar.ParcaSayisi;
            string klasor = _hedefKlasor;

            Task.Factory.StartNew(delegate
            {
                try
                {
                    if (!Directory.Exists(klasor)) Directory.CreateDirectory(klasor);

                    // Cozucu isaretli kayitlarda gercek link indirme aninda uretilir.
                    string[] urls = Cozucu.Coz(k.Cozucu, k.Urls);

                    Job job = Engine.Probe(urls, string.IsNullOrEmpty(k.Referer) ? null : k.Referer);

                    string yol = Path.Combine(klasor, k.Dosya);
                    bool devam = false;

                    long hazir = Engine.InspectResume(yol, job.Total);
                    if (hazir >= 0 && job.AcceptRanges)
                    {
                        devam = true;
                    }
                    else
                    {
                        Engine.DropPartial(yol);
                        if (File.Exists(yol)) yol = BosDosyaYolu(yol);
                    }

                    Engine.Start(job, yol, parca, devam);

                    _saat.Dispatcher.Invoke(new Action(delegate
                    {
                        satir.Yol = yol;
                        satir.Toplam = job.Total > 0 ? job.Total : satir.Toplam;
                        satir.Durum = IndirmeDurumu.Iniyor;
                        _isler[satir] = job;
                        Ornek o = new Ornek();
                        o.Zaman = DateTime.UtcNow;
                        o.Bayt = job.GetReceived();
                        _ornekler[satir] = o;
                        Bildir();
                    }));
                }
                catch (Exception ex)
                {
                    string mesaj = SadeHata(Engine.Flatten(ex));
                    _saat.Dispatcher.Invoke(new Action(delegate
                    {
                        satir.Mesaj = mesaj;
                        satir.Durum = IndirmeDurumu.Hata;
                        Bitir(satir);
                    }));
                }
            });
        }

        private void Tik()
        {
            List<IndirmeSatiri> bitenler = new List<IndirmeSatiri>();

            foreach (KeyValuePair<IndirmeSatiri, Job> p in _isler)
            {
                IndirmeSatiri satir = p.Key;
                Job job = p.Value;

                long inen = job.GetReceived();
                satir.Inen = inen;
                if (job.Total > 0)
                {
                    satir.Toplam = job.Total;
                    satir.Yuzde = Math.Min(100.0, inen * 100.0 / job.Total);
                }

                Ornek o;
                if (_ornekler.TryGetValue(satir, out o))
                {
                    double gecen = (DateTime.UtcNow - o.Zaman).TotalSeconds;
                    if (gecen >= 0.4)
                    {
                        double anlik = (inen - o.Bayt) / gecen;
                        // Yumusatma: ekrandaki sayi zipzip degismesin. Karar verilmez,
                        // sadece gosterilir (motor hiza bakarak hicbir sey yapmaz).
                        o.SonHiz = o.SonHiz <= 0 ? anlik : (o.SonHiz * 0.6 + anlik * 0.4);
                        satir.Hiz = o.SonHiz;
                        o.Zaman = DateTime.UtcNow;
                        o.Bayt = inen;
                    }
                }

                if (job.Finished) bitenler.Add(satir);
            }

            foreach (IndirmeSatiri satir in bitenler)
            {
                Job job = _isler[satir];
                _isler.Remove(satir);
                _ornekler.Remove(satir);

                if (job.Cancelled)
                {
                    satir.Durum = IndirmeDurumu.Iptal;
                }
                else if (!job.Success)
                {
                    satir.Mesaj = SadeHata(job.Error);
                    satir.Durum = IndirmeDurumu.Hata;
                }
                else
                {
                    string uyari = Dogrula(satir.Yol, job.Total);
                    if (uyari == null)
                    {
                        satir.Yuzde = 100;
                        satir.Hiz = 0;
                        satir.Durum = IndirmeDurumu.Tamamlandi;
                    }
                    else
                    {
                        satir.Mesaj = uyari;
                        satir.Durum = IndirmeDurumu.Hata;
                    }
                }

                Bitir(satir);
            }

            if (bitenler.Count > 0 || _kuyruk.Count > 0) KuyruguBesle();
            if (!CalisiyorMu && _isler.Count == 0) _saat.Stop();

            Bildir();
        }

        private void Bitir(IndirmeSatiri satir)
        {
            EventHandler<IndirmeSatiri> h = SatirBitti;
            if (h != null) h(this, satir);
            KuyruguBesle();
            Bildir();
        }

        // Konsoldaki Test-IndirilenDosya ile ayni kontroller: boyut ve dosya imzasi.
        // Sorun yoksa null doner.
        private static string Dogrula(string yol, long beklenen)
        {
            try
            {
                if (!File.Exists(yol)) return "Dosya kayboldu (antivirüs karantinaya almış olabilir)";

                FileInfo fi = new FileInfo(yol);
                if (fi.Length <= 0) return "Dosya boş (0 bayt)";
                if (beklenen > 0 && fi.Length != beklenen)
                    return "Boyut uyuşmuyor (" + fi.Length + " / beklenen " + beklenen + ")";

                byte[] bas = new byte[4];
                using (FileStream fs = new FileStream(yol, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    if (fs.Read(bas, 0, 4) < 2) return null;
                }

                // '<' ile basliyorsa CDN dosya yerine HTML sayfa dondurmus demektir.
                if (bas[0] == 0x3C) return "İçerik HTML görünüyor (indirme linki bir sayfa olabilir)";
                return null;
            }
            catch
            {
                return null;   // dosya kilitli olabilir; basarisiz sayma
            }
        }

        private static string BosDosyaYolu(string yol)
        {
            string dizin = Path.GetDirectoryName(yol);
            string ad = Path.GetFileNameWithoutExtension(yol);
            string uzanti = Path.GetExtension(yol);

            for (int i = 2; i < 1000; i++)
            {
                string yeni = Path.Combine(dizin, ad + " (" + i + ")" + uzanti);
                if (!File.Exists(yeni)) return yeni;
            }
            return yol;
        }

        private static string SadeHata(string ham)
        {
            if (string.IsNullOrEmpty(ham)) return "Bilinmeyen hata";
            string s = ham;
            if (s.IndexOf("404") >= 0) return "Bağlantı bulunamadı (HTTP 404)";
            if (s.IndexOf("403") >= 0 || s.IndexOf("401") >= 0) return "Sunucu erişimi reddetti (403/401)";
            if (s.IndexOf("429") >= 0 || s.IndexOf("503") >= 0) return "Sunucu meşgul (429/503)";
            if (s.IndexOf("timed out") >= 0 || s.IndexOf("zaman") >= 0) return "Zaman aşımı";
            if (s.IndexOf("No such host") >= 0 || s.IndexOf("name or service") >= 0) return "Sunucu adı çözülemedi";
            int nokta = s.IndexOf(" -> ");
            if (nokta > 0) s = s.Substring(0, nokta);
            if (s.Length > 120) s = s.Substring(0, 117) + "...";
            return s;
        }

        // Pencere kapatilirken: calisan isler iptal edilir, yarim dosya diskte kalir.
        public void HepsiniIptalEt()
        {
            foreach (KeyValuePair<IndirmeSatiri, Job> p in _isler)
            {
                try { p.Value.Cancel(); } catch { }
            }
            _kuyruk.Clear();
        }

        // Acilista yarim kalmis indirme var mi?
        public List<string> YarimDosyalar()
        {
            List<string> liste = new List<string>();
            try
            {
                if (!Directory.Exists(_hedefKlasor)) return liste;
                foreach (string d in Directory.GetFiles(_hedefKlasor, "*.indiriliyor"))
                {
                    if (File.Exists(d + ".durum")) liste.Add(d);
                }
            }
            catch { }
            return liste;
        }

        public void YarimlariSil()
        {
            foreach (string d in YarimDosyalar())
            {
                try { File.Delete(d); } catch { }
                try { File.Delete(d + ".durum"); } catch { }
            }
        }

        private void Bildir()
        {
            EventHandler h = Degisti;
            if (h != null) h(this, EventArgs.Empty);
        }
    }
}
