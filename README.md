# Toplu Program İndirici

Konsolda çalışan PowerShell scripti. Program listesini menü olarak gösterir, ok tuşlarıyla gezilir, Space ile seçilir, Enter ile seçilenlerin kurulum dosyaları indirilir.

**Kurulum yapmaz, sadece indirir.** Kurulumu kullanıcı kendisi başlatır.

## Çalıştırma

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\ProgramIndir.ps1
```

Admin yetkisi gerekmez. Harici bağımlılık yoktur — winget, Chocolatey, aria2c veya BITS kullanılmaz, her şey .NET ve Windows'un yerleşik özellikleriyle yapılır.

Windows 10/11, LTSC dahil. PowerShell 5.1 ve 7 ile aynı şekilde çalışır.

## Menü tuşları

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

`Add-Type` ile satır içi C# sınıfı, `System.Net.Http.HttpClient` üzerinden çok parçalı indirme.

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

- `ProgramIndir.ps1`, `apps.json` ve `ayarlar.json` **UTF-8 BOM ile** kaydedilmelidir. BOM'suz kaydedilirse PowerShell 5.1 dosyayı ANSI okur ve Türkçe karakterler bozulur.
- `asenkronDosya` varsayılan olarak kapalıdır. Açıkken 16 parçalı indirme ölçümlerde 4–7 kat yavaşladı (9,9–16,4 MB/s karşı 63,8–71,4 MB/s): her yazmadan önceki `Position` ataması tamponlu async `FileStream`'de senkron flush/seek zorluyor ve 16 thread aynı handle üzerinde seri hale geliyor.
- Sıkıştırma kapalıdır (`Accept-Encoding: identity`). gzip açılınca diske yazılan boyut `Content-Length` ile uyuşmaz, `Range` offsetleri ve boyut doğrulaması bozulur. Sunucu yine de sıkıştırılmış gövde dönerse tek akışa düşülüp açılır.
- Script PowerShell ISE içinde çalışmaz; tuş yakalama desteklenmez.
