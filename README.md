# Toplu Program İndirici

İki arayüz, tek indirme motoru:

- **Konsol** (`ProgramIndir.ps1`) — PowerShell menüsü, ok tuşlarıyla gezilir, Space ile seçilir, Enter ile indirilir. Program listesini `apps.json`'dan **dışarıdan** okur.
- **GUI** (`src/ToplulIndirGui`) — WPF penceresi, kategori kartları + liste. Program listesi derleme zamanında **gömülür**, tek dosya `.exe` olarak dağıtılır.

**Kurulum yapmaz, sadece indirir.** Kurulumu kullanıcı kendisi başlatır.

## Dosya düzeni

```
ProgramIndir.ps1          konsol arayüzü
apps.json                 program listesi (konsol okur, GUI derlemede gömer)
ayarlar.json              indirme ayarları (iki arayüz de aynı dosyayı kullanır)
src/IndirmeMotoru/        ortak indirme motoru (Motor.cs, Cozucu.cs)
src/ToplulIndirGui/       WPF arayüzü
tools/IkonUret.ps1        marka ikonlarını simple-icons'tan üretir
tools/BoyutTazele.ps1     program boyutlarını ölçüp apps.json'a yazar
lib/net48, lib/net8.0     derlenmiş motor DLL'leri (git'e girmez)
```

## Çalıştırma

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\ProgramIndir.ps1
```

Admin yetkisi gerekmez. Harici bağımlılık yoktur — winget, Chocolatey, aria2c veya BITS kullanılmaz, her şey .NET ve Windows'un yerleşik özellikleriyle yapılır.

Windows 10/11, LTSC dahil. PowerShell 5.1 ve 7 ile aynı şekilde çalışır.

GUI için tek dosya `.exe`:

```powershell
dotnet publish src\ToplulIndirGui -c Release -o yayin
.\yayin\TopluProgramIndir.exe
```

Çıktı kendi kendine yeter (self-contained): hedef makinede .NET kurulu olması gerekmez, yanında hiçbir dosya aranmaz.

## Menü tuşları (konsol)

| Tuş | İşlev |
|---|---|
| `↑` `↓` | Gez (liste başında/sonunda sarar) |
| `Space` | Seç / seçimi kaldır |
| `Ctrl+A` | Hepsini seç / hiçbirini seçme |
| harf yaz | O harfle başlayan ilk programa atla |
| `Home` `End` | Listenin başına / sonuna |
| `PgUp` `PgDn` | Bir ekran kaydır |
| `Enter` | Seçilenleri indir |
| `Esc` | Çıkış (`Q` da çıkarır, listede `q` ile başlayan program yoksa) |

## Program ekleme

Sadece `apps.json`'a kayıt ekle, script koduna dokunma. Menü listeyi dinamik kurar, program sayısı hiçbir yerde sabit değildir.

```json
{
  "ad": "Program Adı",
  "url": "https://sunucu/kurulum.exe",
  "dosya": "kurulum.exe",
  "aciklama": "menüde gri gösterilir"
}
```

- `ad` ve `url` zorunlu, diğerleri opsiyonel.
- `dosya` boşsa ad `Content-Disposition` header'ından veya yönlendirme sonrası son URL'den belirlenir.
- `url` dizi de olabilir — birincisi 404/429/timeout verirse sıradakine geçilir:

```json
"url": ["https://birincil/setup.exe", "https://yedek/setup.exe"]
```

- `referer` opsiyoneldir. Bazı sunucular (örneğin `drivers.amd.com`) `Referer` header'ı yoksa dosya yerine hata sayfasına yönlendirir. Verilirse o programın tüm isteklerine eklenir:

```json
"referer": "https://www.amd.com/en/support/download/drivers.html"
```

- `cozucu` opsiyoneldir. Sabit indirme linki vermeyen siteler için kullanılır — `url` indirme **sayfasıdır**, gerçek link indirme anında üretilir. Şu an tek değer: `techpowerup`.

```json
{
  "ad": "GPU-Z",
  "url": "https://www.techpowerup.com/download/techpowerup-gpu-z/",
  "cozucu": "techpowerup"
}
```

  TechPowerUp çözücüsü sayfadaki en yeni sürüm kimliğini bulur, form gönderip ayna sunucu seçer ve 302 yönlendirmesindeki imzalı linki döndürür. Link birkaç saat geçerlidir, bu yüzden menüde değil indirme anında çözülür. Sürüm numarası `apps.json`'a yazılmadığı için GPU-Z güncellendiğinde dosya değişikliği gerekmez. Çözücü kodu `src/IndirmeMotoru/Cozucu.cs` içindedir, GUI de aynı kodu kullanır.

- `kategori` GUI içindir, 7 sabit değerden biri: `tarayici`, `oyun`, `iletisim`, `medya`, `gelistirici`, `araclar`, `redistributable`. Yeni program önce bu yediden birine sığdırılır; yeni kategori ancak en az 5 program birikirse açılır. Konsol bu alanı yok sayar.
- `ikon` GUI'de marka logosu için [simple-icons](https://simpleicons.org) slug'ıdır (`googlechrome`, `steam`, ...). Boş bırakılırsa harf kutucuğu çizilir. Slug ekledikten sonra ikon sözlüğünü yeniden üret:

```powershell
pwsh -File .\tools\IkonUret.ps1
```

- `boyutTahmini` (bayt) GUI listesinde ve toplamda gösterilir. Elle yazmaya gerek yok, ölçüp yazan araç var:

```powershell
pwsh -File .\tools\BoyutTazele.ps1
```

  Dosyaları indirmez; her link için `Range: bytes=0-0` isteğiyle sunucunun bildirdiği boyutu alır.

## GUI

- Açılışta 7 kategori kartı gelir, "Tümü" kategorisi **yoktur** — liste her zaman bir kategori bağlamında görünür.
- Karta tıklayınca liste ekranına geçilir, başlıktaki **‹ Kategoriler** ile geri dönülür. Sol panelden kategoriler arası geçiş doğrudandır.
- Seçim kategoriler arasında korunur: birden fazla kategoriden seçip tek seferde indirilebilir.
- Arama kutusu kategori filtresiyle birlikte (AND) çalışır; kategori ekranında arama yapılırsa kategori ayrımı kalkar, düz sonuç listesi gelir.
- Marka ikonları kendi renklerinde çizilir; arayüzün kendi öğeleri (kategori ikonları, çubuklar, butonlar) antrasit temada kalır.
- Program listesi çalışma anında düzenlenemez — liste derleme zamanında gömülür. Yeni program eklemek için `apps.json` düzenlenip proje yeniden derlenir.
- Sağ tık: **İndirme klasörünü aç**, **Linki kopyala**.
- Pencere kapatılırken indirme sürüyorsa onay istenir; yarım dosyalar diskte kalır, sonraki açılışta "Devam et / Yok say" çubuğu gelir.

## Ayarlar (`ayarlar.json`)

| Alan | Varsayılan | Açıklama |
|---|---|---|
| `parcaSayisi` | 16 | Bir dosya için açılacak paralel bağlantı |
| `esZamanliProgram` | 3 | Aynı anda indirilecek program sayısı |
| `isCalmaEnAzMB` | 8 | Bir parça bu boyuttan büyükse bölünebilir |
| `isCalmaEnFazlaBolme` | 3 | Bir parça en fazla kaç kez bölünür |
| `asenkronDosya` | false | `FileStream useAsync` — bkz. aşağıdaki not |
| `indirmeKlasoru` | "" | Boşsa `Indirilenler\` kullanılır |

Komut satırı bunları ezer: `.\ProgramIndir.ps1 -Parcalar 8 -EsZamanli 2 -Klasor D:\Kurulumlar`

## İndirme motoru

Motor tek kaynaktır: `src/IndirmeMotoru/Motor.cs`. Konsol ve GUI aynı kodu çalıştırır, mantık iki yerde ayrı yazılmaz.

Konsol script motoru şu sırayla yükler:

1. `IndirmeMotoru.dll` — script klasörü, `lib\<hedef>\` veya `src\IndirmeMotoru\bin\Release\<hedef>\` (PowerShell 5.1 → `net48`, PowerShell 7 → `net8.0`)
2. DLL yoksa `src\IndirmeMotoru\*.cs` kaynakları `Add-Type` ile derlenir

Yani DLL derlenmemişse script yine çalışır, sadece ilk açılışta birkaç saniye derleme bekler. DLL üretmek için:

```powershell
dotnet build src\IndirmeMotoru -c Release
```

`System.Net.Http.HttpClient` üzerinden çok parçalı indirme.

- Dosya 16 parçaya bölünür, her parça `Range` header'lı ayrı istekle eşzamanlı iner, tek dosyaya kendi offset'ine yazar. Dosya `SetLength` ile ön-tahsis edilir.
- **İş çalma:** bir parça işini bitirince boşta beklemez, en çok byte'ı kalan parçanın kalan aralığını ikiye böler ve ikinci yarısını devralır. Son parçanın kuyruk etkisini kırar.
- **Kademeli iniş:** sunucu 429/503 dönerse eşzamanlılık yarılanır (16 → 8 → 4 → 2 → 1) ve başarılı kademede kalınır. Hız düşmesi tek başına hiçbir şeyi tetiklemez.
- Aynı host'tan iki dosya asla eşzamanlı indirilmez.
- Ölçüm, hız testi veya öğrenilen hız profili yoktur. Ekrandaki hız yalnızca bilgi içindir.

## İptal ve devam

`Ctrl+C` yakalanır, yarım dosya `.indiriliyor` uzantısıyla diskte bırakılır, yanına segment offsetlerini tutan `.indiriliyor.durum` yazılır. Script tekrar çalıştırıldığında **Devam et / Baştan indir / Sil** sorulur. Hedef dosya ancak indirme bitip doğrulama geçtikten sonra oluşur.

## Doğrulama

Her dosya için sırayla: boyut `Content-Length` ile eşleşiyor mu, ilk iki byte `MZ` mi (yoksa CDN'den HTML hata sayfası gelmiş olabilir), `Get-AuthenticodeSignature` imza durumu. İmza geçersizse dosya silinmez, özet tabloda uyarı olarak işaretlenir.

## Notlar

- GUI'yi derlemek için .NET SDK 10 gerekir; scriptin çalışması için gerekmez.
- `src/ToplulIndirGui/Assets/Ikonlar.xaml` üretilmiş dosyadır, elle düzenlenmez — `tools/IkonUret.ps1` yeniden üretir.
- `ProgramIndir.ps1`, `apps.json` ve `ayarlar.json` **UTF-8 BOM ile** kaydedilmelidir. BOM'suz kaydedilirse PowerShell 5.1 dosyayı ANSI okur ve Türkçe karakterler bozulur.
- `asenkronDosya` varsayılan olarak kapalıdır. Açıkken 16 parçalı indirme ölçümlerde 4–7 kat yavaşladı (9,9–16,4 MB/s karşı 63,8–71,4 MB/s): her yazmadan önceki `Position` ataması tamponlu async `FileStream`'de senkron flush/seek zorluyor ve 16 thread aynı handle üzerinde seri hale geliyor.
- Sıkıştırma kapalıdır (`Accept-Encoding: identity`). gzip açılınca diske yazılan boyut `Content-Length` ile uyuşmaz, `Range` offsetleri ve boyut doğrulaması bozulur. Sunucu yine de sıkıştırılmış gövde dönerse tek akışa düşülüp açılır.
- Script PowerShell ISE içinde çalışmaz; tuş yakalama desteklenmez.

## Lisans ve Kullanım Koşulları

**Telif Hakkı © 2026 Alper İbrahimağaoğlu — Tüm Hakları Saklıdır (All Rights Reserved).**

Bu depo **açık kaynak değildir**. Kodun herkese açık olarak görüntülenebilir olması, serbestçe kullanılabileceği anlamına gelmez. Tam hukuki metin için [LICENSE](LICENSE) dosyasına bakınız.

### İzin verilenler

- Kaynak kodu kişisel veya eğitim amacıyla görüntülemek ve incelemek.
- Değiştirilmemiş bir kopyayı indirip kendi cihazınızda kişisel, ticari olmayan amaçla çalıştırmak.

### Yazılı izin olmadan yasaklananlar

- **Değiştirme / türev eser (No Derivatives):** kodu düzenlemek, uyarlamak, çevirmek veya ondan türetilmiş bir sürüm üretmek.
- **Yeniden dağıtım (No Redistribution):** kodu kopyalayıp başka bir depoda, web sitesinde, mağazada veya platformda yayımlamak, aynalamak (mirror), yeniden yüklemek.
- **Ticari kullanım (No Commercial Use):** satmak, kiralamak, lisanslamak veya bir ürün/hizmetin parçası hâline getirmek.
- Kaynak dosyalardaki telif başlıklarını veya lisans dosyasını kaldırmak ya da değiştirmek.
- Kodu yapay zekâ modeli eğitiminde veri kümesi olarak kullanmak.

### Atıf zorunluluğu

Bu projeye yapılan her referans, alıntı veya bahis; **Alper İbrahimağaoğlu** adını ve bu deponun bağlantısını açıkça belirtmek zorundadır:

> Toplu Program İndirici — © 2026 Alper İbrahimağaoğlu
> https://github.com/alperagaoglu61/toplu-uygulama-indir

### Üçüncü taraf yazılımlar ve markalar

Bu araç hiçbir kurulum dosyasını barındırmaz veya yeniden dağıtmaz; yalnızca üreticilerin **resmî sunucularından** indirir. İndirilen her programın kendi lisans koşulları geçerlidir. `apps.json` içindeki marka adları ve `Assets/Ikonlar.xaml` içindeki ikonlar ilgili sahiplerine aittir; ikon yolları [simple-icons](https://simpleicons.org) (CC0) kaynağından üretilmiştir. Bu lisans yalnızca telif sahibinin yazdığı kodu kapsar.

### Sorumluluk reddi

Yazılım "olduğu gibi" sunulur, hiçbir garanti verilmez. İnternetten dosya indirir ve diske yazar; indirilen dosyaların içeriği, güvenliği veya güncelliği telif sahibinin sorumluluğunda değildir. Oluşabilecek veri kaybı, ağ maliyeti veya sistem kararsızlığından telif sahibi sorumlu tutulamaz. Tüm risk kullanıcıya aittir.

Yukarıda yasaklanan kullanımlar için izin talebi: https://github.com/alperagaoglu61
