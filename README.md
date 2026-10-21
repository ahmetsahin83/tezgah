<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Tezgah ikonu">
</p>

<h1 align="center">Tezgah</h1>

<p align="center">
  <b>Projeler, terminaller, git, veritabanı ve yapay zekâ ajanları için tek pencerelik, native bir macOS çalışma alanı.</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/SwiftUI-native-0A84FF" alt="SwiftUI">
  <img src="https://img.shields.io/badge/Claude%20Code-%26%20Codex-D97757" alt="Claude Code ve Codex">
  <a href="CHANGELOG.md"><img src="https://img.shields.io/github/v/tag/ahmetsahin83/tezgah?sort=semver&label=s%C3%BCr%C3%BCm&color=6E56CF" alt="Sürüm"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/lisans-MIT-2EA44F" alt="MIT lisansı"></a>
</p>

<p align="center">
  <a href="#neden-tezgah">Neden Tezgah?</a> ·
  <a href="#özellikler">Özellikler</a> ·
  <a href="#kurulum">Kurulum</a> ·
  <a href="#kısayollar">Kısayollar</a> ·
  <a href="#geliştirme">Geliştirme</a> ·
  <a href="#lisans">Lisans</a>
</p>

<p align="center"><img src="docs/screenshots/ana-pencere.png" width="900" alt="Tezgah ana pencere"></p>

---

## Neden Tezgah?

Bir editör, birkaç terminal, bir git istemcisi, bir veritabanı aracı, bir tarayıcı ve bir de yapay zekâ ajanları için
ayrı pencereler... Tezgah hepsini tek bir native pencerede topluyor ve ajanları bu araçlara bağlıyor.

- **Ajanlar birinci sınıf vatandaş.** Claude Code ve Codex oturumları sohbet görünümüyle, onaylarıyla, maliyet ve bağlam
  bilgisiyle sekmede yaşar. Tarayıcıyı, iOS Simülatörü'nü, veritabanını, terminali ve panoyu kendileri kullanabilir.
- **Kart ver, iş birleşsin.** Panodaki bir kart **Orkestra**'ya gider: planlanır, kendi worktree'sinde geliştirilir,
  gözden geçirilir ve birleştirilir. İstersen Yapılacak sütununun tamamı sırayla yürür, sen de Telegram'dan takip edersin.
- **Native ve hafif.** SwiftUI, [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) ve
  [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor) ile yazıldı. Electron yok.

## Özellikler

### Orkestra: karttan birleştirmeye

Panodaki bir kartı **Orkestrayla Başlat** ile ekibe ver; kart kendiliğinden yürür.

```mermaid
flowchart LR
    K["Pano kartı"] --> P["Planlayıcı<br/>plan ve bitti ölçütleri"]
    P -- "bilgi ya da karar gerekiyor" --> S["Sana sorar"]
    S -- "Cevapla ve Baştan Başlat" --> P
    P --> G["Geliştirici<br/>kendi worktree'sinde commit'ler"]
    G --> R["Gözden geçirenler<br/>salt okunur, build ve test"]
    R --> D{"Karar verici"}
    D -- "değişiklik iste" --> G
    D -- "onay" --> M["Birleştir<br/>istenirse push'la"]
    M -- "çakışma" --> G
    M --> B["Bitti"]
```

<p align="center"><img src="docs/screenshots/kosu-sayfasi.png" width="900" alt="Orkestra koşu sayfası"></p>

- **Planlayıcı** (Claude ya da Codex, salt okunur) kartı okur, kodu tarar ve `plan_ready` ile bir plan verir: işi nasıl
  anladığı, yaklaşım, "bitti" ölçütleri, işe dahil edilen küçük katkılar ve ayrı iş önerileri. Plan kartta saklanır;
  gözden geçirenler ve karar verici işi bu ölçütlere göre kontrol eder. Büyük fikirler karta katılmaz, koşu sayfasındaki
  **Panoya Ekle** ile Yapılacak'ın sonuna yeni kart olur.
- **Geliştirici** kendi worktree'sinde ve dalında çalışıp commit'ler. Soru sorup seni beklemez: belirsiz yerde makul
  olanı seçer ve varsayımlarını commit mesajına yazar.
- **Gözden geçirenler** istediğin kadar olabilir; her birinin kendi ajanı, modeli ve odağı vardır. Build, vet ve testleri
  çalıştırabilirler, kaynak dosyalara dokunmazlar. Birden çok gözden geçiren varsa **karar verici** hepsini tartar.
- **Birleştirme** öncesinde çakışma `git merge-tree` ile, çalışma kopyasına dokunmadan kontrol edilir. Çakışma varsa
  geliştirici ana dalı birleştirip çözer, çözüm de gözden geçirilir (en fazla 2 deneme). **Birleşince push'la** açıksa
  dal her birleştirmeden sonra uzak depoya gönderilir (zorla değil).
- **Ekip** proje başına ayarlanır: her üyenin ajanı, modeli, düşünme seviyesi (Claude'a `--effort`, Codex'e
  `model_reasoning_effort` olarak gider) ve gözden geçirenlerin odağı.
- **Sırayla Yürüt**, Yapılacak'taki kartları üstten başlayarak teker teker orkestraya gönderir. Takılan kart dalı ve
  worktree'siyle Yapılıyor'da kalır, sıra sürer; üst üste 2 kart takılırsa sıra durup haber verir.
- **Koşu sayfası** her kartın orkestrasını kendi sekmesinde gösterir: aşamalar ve tur, her ajan için bir kart (rol, ajan ·
  model · odak, durum, o an çalıştırdığı komut, dokunduğu dosyalar, gözden geçirenin kararı ve notu) ve adım adım akış.
  Akış kartın üzerinde saklanır, Bitti'deki kartlarda da görünür.
- **Kaldığı yerden sürer.** Tezgah kapanıp açılınca koşular ve sıra kaldıkları yerden devam eder.

<details>
<summary><b>Takılan kartlar, süre sınırları ve sorular</b></summary>

- Kart yapılamıyorsa ya da senden bilgi, erişim veya karar gerekiyorsa planlayıcı tahminle ilerlemez: `blocked` ve
  `questions` ile durdurur. Koşu sayfasında sorular ve bir cevap kutusu çıkar; **Cevapla ve Baştan Başlat** cevabı kartın
  notuna ekleyip kartı baştan başlatır. Bu, sıranın "üst üste takılma" sayacına girmez.
- Planlayıcı planı araçla vermezse bir kez hatırlatılır, sonra yazdıkları plan sayılır. Başlatılamazsa ya da oturumu
  kapanırsa iş plansız sürer.
- Her adımın süre sınırı vardır (Ekip penceresinden; varsayılan planlama 30, geliştirme 90, gözden geçirme 30 dakika).
  Aşılırsa ajanın turu kesilir, kart takılmış sayılır ve sıra sürer.
- Orkestra tur sınırında, çözülemeyen çakışmada ya da commit'siz bitişte durup haber verir. Ekip'te tur sınırı 0
  yapılırsa hiçbir kart tura takılmaz (adımların süre sınırları yine geçerlidir).
- Duran her kart **Devam Et** ile aynı dalda kaldığı yerden sürer ve o kartta tur sınırı kalkar: yeni commit varsa
  gözden geçirmeye gider, commit'lenmemiş iş varsa tamamlanıp commit'lenir, yoksa son istenen değişiklikler
  geliştiriciye gider; süre sınırında duran adım yeniden başlar. Duran kartın geliştiricisi commit atmadan bir tur daha
  bitirirse kart yeniden durdurulmaz, ilk nedeni kalır.
- **Baştan Başlat** dalı ve worktree'yi silip kartı yeniden başlatır (dalda iş varsa önce sorar); sıra açıksa kart
  Yapılacak'ın başına geçer.
- Yeniden açılışta yarım kalan planlama ve gözden geçirme baştan yapılır, geliştiriciye devam etmesi söylenir (oturumu
  geri gelmediyse ve dalda iş yoksa yerine yenisi plan ve son istenenlerle başlar), yarım kalan birleştirme tamamlanır.
- Gözden geçirenlerin worktree'de bıraktığı değişiklikler (dosya, yeni dosya, commit) her gözden geçirme bitince geri
  alınıp akışa yazılır; `.gitignore`'daki derleme çıktıları kalır.
- Orkestranın Claude ajanlarında soru aracı (`AskUserQuestion`) kapalı açılır.
- Uzun yazılar (gözden geçirme notları, ajanın son söylediği, commit listeleri) koşu sayfasında birkaç satırda kısalır,
  **Tamamını göster** ile açılır ve seçilip kopyalanabilir.

</details>

### Claude Code ve Codex

<p align="center"><img src="docs/screenshots/claude-sohbet.png" width="900" alt="Claude sohbet görünümü"></p>

- **Sohbet görünümü:** transkriptten canlı konuşma; markdown, renkli kod, satır içi diff'ler, katlanan komut ve okuma
  adımları, sabit yapılacaklar çubuğu, canlı alt ajan adımları, dosya linkleri. Bash komutlarını ve `bash` kod bloklarını
  yandaki terminalde tek tıkla yeniden çalıştırabilirsin. Ajanın kendi terminal arayüzü <kbd>⌘J</kbd> ile bir tık uzakta.
- **Native composer:** `@` ile dosya, `/` ile komut, görsel yapıştırma ve sürükleme, prompt geçmişi. Her turdan sonra
  ne sorabileceğine dair üç öneri gelir (<kbd>Tab</kbd> ile al).
- **Durum takibi:** çalışıyor / onay bekliyor / bitti, bildirim, Dock rozeti ve tüm oturumlara genel bakış
  (<kbd>⇧⌘A</kbd>). İzin ve soru kartları; onaylar bildirimden, genel bakıştan ya da sekmenin üstündeki şeritten
  yanıtlanır (İzin Ver / Bir Daha Sorma / Reddet).
- **Görünürlük:** bağlam doluluğu, plan limitleri (5 saat / haftalık), satır ve maliyet; oturumun kendi diff'i (oturum
  başındaki çalışma ağacına göre) ve dokunulan dosyalar. Sohbette arama ve mesaj aksiyonları (kopyala / düzenle / tekrar
  gönder).
- **Uzaktan erişim (Remote Control):** oturum Mac'te sürer, Claude uygulamasından ya da claude.ai/code'dan takip edilip
  yanıtlanır. Durum çubuğunda 📡, QR kodlu bağlantı; açıkken Mac uyumaz.
- **Codex:** sohbet görünümü Codex'in oturum kaydından canlı beslenir (mesajlar, komutlar ve çıktıları, renkli diff'ler,
  MCP çağrıları, tur süreleri). Onay seçenekleri Codex'in ekranından okunur. `~/.codex`'e dokunulmaz.
- **Onaysız çalışma (isteğe bağlı):** Ayarlar › Claude › "Ajanlar onay istemesin" açıkken Claude oturumları
  `--dangerously-skip-permissions`, Codex oturumları `--dangerously-bypass-approvals-and-sandbox` ile açılır; orkestra ve
  lider ajanın işleri izin beklemeden yürür.
- **Başında beklemeden (varsayılan açık):** Ayarlar › Claude › "Ajanlar kendi başına yürüsün" açıkken ajanın açıldığı
  klasöre (worktree ve ana depo dahil) önceden güvenilir, "Trust this folder?" ekranı çıkmaz; Codex'in güncelleme ekranı
  atlanır. Kullanım limiti dolan ajan ekranından okunan sıfırlanma saatini bekler ve kendiliğinden devam eder; Claude'un
  limit menüsünde beklemeyi seçer, Telegram bağlıysa haber verir. Beklenen süre orkestra adımının süre sınırına sayılmaz.
- **Oturum ayarları:** çalışan bir Claude oturumunun izin modu (Her şeyi sor / Düzenlemeleri kabul et / Plan /
  Otomatik / Tam yetki), modeli ve düşünme seviyesi sekmenin üstünden değiştirilir.
- **MCP sunucuları:** Ayarlar › MCP Sunucuları'ndan Claude'a MCP sunucusu eklenir; Sentry, Linear, Context7 ve GitHub
  hazır gelir.

### Lider ajan

Her Claude ya da Codex oturumu işi başka ajanlara bölebilir. Her ajan kendi worktree'si ve dalında, istenen sağlayıcı ve
modelle, yeni bir sekmede çalışır.

| Araç | Ne yapar |
|---|---|
| `agent_spawn` | Yeni bir ajan başlatır |
| `agent_wait` | Ajanların bitmesini ya da kullanıcı onayı beklemesini bekler; son cevaplarını ve commit'lerini getirir |
| `agent_send` | Çalışan bir ajana mesaj gönderir |
| `agent_merge` | Ajanın dalını birleştirir |
| `agent_stop` | Ajanı durdurur |
| `agent_list` | Liderin ajanlarını listeler |

Liderin başlattığı ajanlar sekmede ve genel bakışta **↳** ile görünür. Tezgah yeniden açılınca lider ile ajanları yine
birbirini bulur ve lidere işi sürdürmesi söylenir.

### Tezgah araçları

Tezgah, Claude ve Codex'e yerel bir MCP sunucusu üzerinden kendi araçlarını verir. Claude çalışırken ilgili sekme
sohbetin yanında açılır.

| Araç | Neler yapılabilir |
|---|---|
| Tarayıcı | Aç, oku, tıkla, yaz, kaydır, JavaScript çalıştır, ekran görüntüsü, konsol, cihaz boyutu |
| iOS Simülatörü | Cihazları listele, aç, kur, başlat, ekran görüntüsü, erişilebilirlik ağacı, dokun, kaydır, yaz, donanım tuşları, URL aç, açık / koyu görünüm, loglar |
| Pano | Kartları listele, ekle, düzenle, taşı |
| Veritabanı | Bağlantılar, şema, sorgu. Veri değiştiren her komut için kimin istediğini gösteren onay |
| Terminal | Komut çalıştır, çıktısını oku, durdur. Dev sunucusu gibi uzun işler kendi terminalinde |
| Editör | Açık dosya, imleç, seçili metin; dosyayı editörde açma |

Ajanlar veritabanını kendi arka plan bağlantısında sorgular: seni veritabanı sekmesine çekmez, oradaki sonuçlarına ve
açık transaction'ına dokunmaz. Her sorgu bağlantının geçmişine ajanın adıyla yazılır; orkestra ajanlarının sorguları
sonucuyla birlikte kartın akışına da düşer.

### Proje panosu

<p align="center"><img src="docs/screenshots/pano.png" width="900" alt="Proje panosu"></p>

- Yapılacak / Yapılıyor / Bitti sütunları, sürükle-bırak, tek tıkla bitti, notlar.
- **Claude'a ver:** kart prompt olur ve Yapılıyor'a geçer.
- Kartı kendi worktree'sinde ve dalında bir ajana verme (Claude ya da Codex): `.tezgah/worktrees/<kart>` üzerinde
  `tezgah/<kart>` dalı, kart ilk mesaj olarak gider; iş bitince karttan birleştir ya da sil.
- `.tezgah/` deponun kendi `info/exclude`'una eklenir; projende hiçbir dosya değişmez.

### Telegram

Kendi botunla (BotFather) Tezgah'ı telefondan takip et. Sunucu gerekmez (long polling); Mac açık ve Tezgah çalışıyor
olmalı.

<!-- EKRAN GÖRÜNTÜSÜ (Telegram): telefondaki bildirimler ve düğmeler. Dikey bir telefon görüntüsü, dar tutuldu.
     Görseli docs/screenshots/telegram.png olarak kaydet, sonra alttaki satırı bu yorumun dışına taşı.
<p align="center"><img src="docs/screenshots/telegram.png" width="320" alt="Telegram bildirimleri"></p>
-->

- **Bildirimler:** kart birleşti (push'landıysa o da), takıldı (Koşuyu Göster / Baştan Başlat), planlayıcının soruları
  (mesajı yanıtlamak cevaplar ve kartı baştan başlatır), sıra bitti ya da durdu, ajan onay bekliyor (İzin Ver / Bir Daha
  Sorma / Reddet). Veritabanı değiştirme onayı Mac'teki pencereyle aynı anda telefona da gelir; hangisi önce yanıtlanırsa
  o geçer.
- **Komutlar:** `/durum`, `/kartlar` (her kart için Başlat / Koşu / Devam / Durdur / Baştan), `/kart Başlık`, `/sira`,
  `/projeler`, `/proje ad`, `/yardim`.
- **Gizlilik:** yalnızca eşleşen hesap dinlenir; mesajlarda özet olur, kod ve sorgu sonuçları gönderilmez.

Kurulum: Ayarlar › Telegram'da bot token'ını yapıştır, çıkan kodu bota gönder. Bot eşleşmişken Mac uyumaz (Ayarlar'dan
kapatılabilir).

### Editör, terminal ve git

- **Editör:** tree-sitter ile 40+ dilde syntax highlighting, satır numaraları, otomatik girinti algılama, editörde git
  değişiklik işaretleri (index'e göre canlı), yan yana görünüm, Markdown önizleme (GFM) ve görsel görüntüleyici.
- **Gezinme:** hızlı dosya açma (<kbd>⌘P</kbd>, `dosya:42` ile satıra git), komut paleti, projede arama (ripgrep /
  git grep / grep; regex, tam kelime, dosya filtresi), <kbd>⌘K</kbd> ile ara ya da Claude'a sor.
- **Terminal:** proje başına sekmeler; sekmeler ve terminaller yeniden açılışta geri gelir. Sekme kapanınca içinde
  çalışan iş gerçekten durur.
- **Proje komutları:** Makefile, `package.json`, `Package.swift`… otomatik bulunur; <kbd>⌘R</kbd> son komutu tekrarlar.
  Make menüsü hedefleri `##` ya da üstteki yorumdan açıklamalarıyla listeler, <kbd>⌃1</kbd>…<kbd>⌃9</kbd> ile çalıştırır.
- **Git paneli:** durum, diff (editörle aynı temada renkli), stage, commit, geçmiş ve commit grafiği, branch,
  fetch / pull / push.
- **Canlı izleme (FSEvents):** dosya ağacı, git durumu ve açık dosyalar dışarıdaki değişiklikleri takip eder.
- **Kapatırken koruma:** kaydedilmemiş dosyalar ve terminallerde çalışan işlemler için uyarı.
- **Pencere:** proje avatarı ve branch rozetli araç çubuğu, yuvarlak sekmeler, pencere geneli durum çubuğu (branch,
  Claude, bağlantılar, çalışan komutlar, oturum bilgisi), üst klasöre göre proje grupları.

### Veritabanı

PostgreSQL, MySQL / MariaDB ve SQLite; proje başına bağlantılar, parolalar Keychain'de.

<p align="center"><img src="docs/screenshots/veritabani.png" width="900" alt="Veritabanı sekmesi"></p>

- `.env` içindeki `DATABASE_URL`'i ve projedeki SQLite dosyalarını bağlantı olarak önerir. SSH tüneli desteklenir.
- **SQL editörü:** FROM / JOIN sonrası tablolar, ifadedeki tabloların kolonları, `alias.` üyeleri, foreign key'e göre hazır
  JOIN, `*` açma, anahtar kelime ve fonksiyon tamamlama. SQL biçimlendirme, hatanın editörde işaretlenmesi.
- **Sorgular:** iptal ve süre, sorgu geçmişi, `EXPLAIN` / `EXPLAIN ANALYZE` planı, elle commit modu, veri silebilecek
  komutlarda onay.
- **Tablolar:** kolonlar ve indeksler, çift tıkla düzenleme, NULL, satır ekle / sil, SQL önizleme, tek işlemde kaydet;
  WHERE filtresi, başlıkla sıralama, sayfalama, foreign key'le ilişkili satıra gitme.
- **Sonuçlar:** TSV / JSON kopyalama, CSV dışa aktarma.

### Önizleme: tarayıcı ve iOS Simülatörü

- **Tarayıcı** (<kbd>⇧⌘B</kbd>): adres çubuğu, cihaz boyutları, konsol.
- **iOS Simülatörü** (<kbd>⇧⌘I</kbd>): canlı ekran, dokunma ve kaydırma. Dokunma, kaydırma ve yazma
  [AXe](https://github.com/cameroncooke/AXe) ile yapılır; geri kalan her şey Xcode'un `simctl` aracıyla çalışır.

## Kurulum

### İndir

[Releases](https://github.com/ahmetsahin83/tezgah/releases/latest) sayfasından son sürümün `.dmg` dosyasını indir, aç ve
**Tezgah**'ı **Applications** klasörüne sürükle.

> [!NOTE]
> Tezgah ad-hoc imzalı ve Apple tarafından notarize edilmedi. İlk açılışta macOS uygulamayı engellerse
> Sistem Ayarları › Gizlilik ve Güvenlik'teki **Yine de Aç**'a bas ya da karantina işaretini kaldır:
>
> ```bash
> xattr -dr com.apple.quarantine /Applications/Tezgah.app
> ```

### Gereksinimler

| | Gerekenler |
|---|---|
| **Zorunlu** | macOS 14 Sonoma ya da üstü; hazır DMG yalnızca Apple Silicon (M serisi) Mac'lerde çalışır |
| **Kaynaktan derlemek için** | Xcode (Swift 6) |
| **Ajanlar için** | [Claude Code](https://claude.com/claude-code) (`curl -fsSL https://claude.ai/install.sh \| bash`) ve/veya [Codex](https://github.com/openai/codex) (`brew install codex`) |
| **İsteğe bağlı** | [ripgrep](https://github.com/BurntSushi/ripgrep) (daha hızlı proje araması), [AXe](https://github.com/cameroncooke/AXe) (simülatörde dokunma: `brew install cameroncooke/axe/axe`) |

AXe kurulu değilse Cihaz sekmesindeki **AXe'yi Kur** butonu kurulumu bir terminalde başlatır.

### Kaynaktan derle

```bash
git clone https://github.com/ahmetsahin83/tezgah.git
cd tezgah
make install    # release derler, ad-hoc imzalar ve /Applications altına kopyalar
```

| Komut | Ne yapar |
|---|---|
| `make run` | Release derler, `build/Tezgah.app` oluşturur ve açar |
| `make install` | Uygulamayı `/Applications` altına kopyalar |
| `make app` | Sadece `.app` paketini oluşturur |
| `make dmg` | `.app`'i `build/Tezgah-<sürüm>.dmg` olarak paketler |
| `make icon` | `Support/AppIcon.icns`'i `Support/make-icon.swift`'ten yeniden üretir |
| `make clean` | Derleme çıktılarını siler |

## Kısayollar

<details open>
<summary><b>Genel</b></summary>

| Kısayol | İşlem |
|---|---|
| <kbd>⌘K</kbd> | Ara ya da Claude'a sor: dosya, komut (`>`) ya da yazdığını Claude'a gönder |
| <kbd>⌘P</kbd> | Hızlı aç, <kbd>⌘K</kbd> ile aynı panel (`dosya:42` ile satıra git, `:42` açık dosyada) |
| <kbd>⇧⌘P</kbd> | Komut paleti (Hızlı Aç'ta `>` ile de açılır) |
| <kbd>⇧⌘F</kbd> | Projede ara (seçili metinle açılır; regex, tam kelime, dosya filtresi) |
| <kbd>⌘R</kbd> | Son proje komutunu tekrar çalıştır |
| <kbd>⌃1</kbd> … <kbd>⌃9</kbd> | Makefile hedeflerini çalıştır (Make menüsündeki sırayla) |
| <kbd>⌘O</kbd> | Proje ekle |
| <kbd>⌘T</kbd> | Aktif projede yeni terminal |
| <kbd>⌘1</kbd> … <kbd>⌘9</kbd> | Projeler arasında geçiş |
| <kbd>⇧⌘]</kbd> / <kbd>⇧⌘[</kbd> | Sonraki / önceki sekme |
| <kbd>⌘W</kbd> | Sekmeyi kapat |
| <kbd>⇧⌘K</kbd> | Proje panosu (Yapılacak / Yapılıyor / Bitti) |
| <kbd>⇧⌘B</kbd> | Tarayıcı önizleme (adres, cihaz boyutları, konsol) |
| <kbd>⇧⌘I</kbd> | iOS Simülatörü (canlı ekran, dokun / kaydır) |

</details>

<details>
<summary><b>Editör</b></summary>

| Kısayol | İşlem |
|---|---|
| <kbd>⌘S</kbd> | Dosyayı kaydet |
| <kbd>⌥⌘S</kbd> | Tümünü kaydet |
| <kbd>⌘\\</kbd> | Yan yana böl / bölmeyi kapat (sekmeye sağ tık: "Yan Tarafta Aç") |
| <kbd>⇧⌘V</kbd> | Markdown önizleme: kaynak ↔ yan yana (yalnızca önizleme sekmedeki seçiciden) |
| <kbd>⌘F</kbd> | Editörde bul |
| <kbd>⌘/</kbd> | Satırı yorum yap / kaldır |
| <kbd>⌘[</kbd> / <kbd>⌘]</kbd> | Girintiyi azalt / artır |

</details>

<details>
<summary><b>Claude ve Codex</b></summary>

| Kısayol | İşlem |
|---|---|
| <kbd>⇧⌘C</kbd> | Yeni Claude oturumu (<kbd>⌥⇧⌘C</kbd>: son oturumu sürdür) |
| <kbd>⇧⌘X</kbd> | Yeni Codex oturumu (<kbd>⌥⇧⌘X</kbd>: son oturumu sürdür) |
| <kbd>⌘J</kbd> | Sohbet / terminal görünümü |
| <kbd>⇧⌘A</kbd> | Tüm ajan oturumları (onay bekleyenler yerinde yanıtlanır) |
| <kbd>↩</kbd> / <kbd>⇧↩</kbd> | Composer'da gönder / yeni satır (<kbd>↑</kbd> önceki prompt'lar, <kbd>Esc</kbd> durdur, <kbd>⌘↩</kbd> izin ver) |
| <kbd>⌘F</kbd>, <kbd>↩</kbd> / <kbd>⇧↩</kbd> | Sohbette ara, sonraki / önceki eşleşme (<kbd>⌘G</kbd> de sonraki) |

</details>

<details>
<summary><b>Git</b></summary>

| Kısayol | İşlem |
|---|---|
| <kbd>⇧⌘G</kbd> | Sağdaki git panelini aç / kapat (diff'ler sekmede açılır, çift tık sekmeyi sabitler) |
| <kbd>⌘↩</kbd> | Commit mesajını yazarken commit |

</details>

<details>
<summary><b>Veritabanı</b></summary>

| Kısayol | İşlem |
|---|---|
| <kbd>⌘↩</kbd> / <kbd>⇧⌘↩</kbd> | İmleçteki ifadeyi (ya da seçimi) / tüm ifadeleri çalıştır |
| <kbd>⌥⌘L</kbd> | SQL'i biçimlendir |
| <kbd>⌘.</kbd> | Çalışan sorguyu iptal et |
| <kbd>⌃Space</kbd> / <kbd>Esc</kbd> | Tamamlama listesini aç |

</details>

## Geliştirme

```bash
swift build     # sadece derleme kontrolü
swift test      # testler (geçici git depolarında çalışır)
```

### Proje yapısı

```text
Sources/Tezgah/
├── TezgahApp.swift      Giriş noktası
├── Model/
│   ├── Agent/           Sağlayıcıdan bağımsız oturum takibi, Codex transkripti ve onayları
│   ├── Claude/          Claude oturumları, transkript, composer, Remote Control, bildirimler
│   ├── Orchestra/       Orkestra koşuları, ekip, sıra, saklanan koşular
│   ├── MCP/             Yerel MCP sunucusu ve Tezgah araçları
│   ├── Git/             Git komutları, diff, commit grafiği, worktree'ler
│   ├── Database/        PostgreSQL, MySQL ve SQLite istemcileri, SQL lexer, biçimlendirici, tamamlama, SSH tüneli
│   ├── Telegram/        Bot, komutlar, duyurular
│   └── …                Proje, pano, terminal, dosya izleme, arama, ayarlar
├── Views/               SwiftUI arayüzü (Claude, Orchestra, Git, Database alt klasörleri)
└── Debug/               Debug derlemelerde arayüz otomasyonu
Support/                 Info.plist, uygulama ikonu ve ikonu çizen betik
Tests/TezgahTests/       Swift Testing ile testler
```

### Veritabanı testleri

SQLite testleri her zaman çalışır. Postgres ve MySQL testleri için bir sunucu adresi ver:

```bash
TEZGAH_TEST_POSTGRES_URL='postgres://postgres:parola@127.0.0.1:5432/app' \
TEZGAH_TEST_MYSQL_URL='mysql://root:parola@127.0.0.1:3306/app' \
TEZGAH_TEST_MARIADB_URL='mariadb://root:parola@127.0.0.1:3307/app' swift test
```

### Geliştirme kopyası

Günlük kullandığın Tezgah açıkken branch'teki sürümü yan yana denemek için durumu ayrı bir klasörde tut. Geliştirme
kopyası Telegram botunu dinlemez.

```bash
swift build
TEZGAH_SUPPORT_DIR=/tmp/tezgah-dev .build/debug/Tezgah
```

### Arayüz otomasyonu

Debug derlemelerde `TEZGAH_DEBUG_DIR` verilirse uygulama o klasöre bırakılan `*.cmd` dosyalarını çalıştırır (`snapshot`,
`type`, `send`, `key`, `press`, `click`, `scroll`, `keys`, `menu`, `view`, `appearance`, `size`, `tab`, `js`, `card`,
`overview` ve diğerleri). Böylece ekran kaydı izni olmadan arayüz kontrol edilebilir. Ayrıntılar
[`Sources/Tezgah/Debug/DebugAutomation.swift`](Sources/Tezgah/Debug/DebugAutomation.swift) içinde.

### Sürüm çıkarma

Sürümler [Semantic Versioning](https://semver.org/) ile numaralanır (`MAJOR.MINOR.PATCH`) ve her sürüm bir `vX.Y.Z`
tag'i taşır. Değişiklikler [CHANGELOG.md](CHANGELOG.md)'de tutulur.

1. `CHANGELOG.md`'ye yeni sürümün başlığını ve değişikliklerini ekle.
2. `Support/Info.plist`'te `CFBundleShortVersionString`'i yeni sürüme getir, `CFBundleVersion`'ı bir artır.
3. Commit'le, tag'le ve gönder:

```bash
git tag -a v1.1.0 -m "Tezgah 1.1.0"
git push origin main v1.1.0
```

4. DMG'yi üret ve sürümün GitHub release'ine ekle (notlara `CHANGELOG.md`'deki bölümü yaz):

```bash
make dmg
gh release create v1.1.0 build/Tezgah-1.1.0.dmg --title "Tezgah 1.1.0"
```

## Yol haritası

- [ ] Git: satır / hunk bazında stage, amend, stash

Fikrin ya da bulduğun bir hata varsa [issue](https://github.com/ahmetsahin83/tezgah/issues) açabilirsin.

## Katkı

Katkılara açığım. Pull request göndermeden önce:

1. `swift build` ve `swift test`'in geçtiğinden emin ol.
2. Değişikliği küçük ve odaklı tut; davranış değişiyorsa test ekle.
3. Büyük bir değişiklik düşünüyorsan önce bir issue açıp konuşalım.

## Teşekkürler

Tezgah şu açık kaynak projelerin üzerinde duruyor:
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm),
[CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor),
[CodeEditLanguages](https://github.com/CodeEditApp/CodeEditLanguages),
[SwiftTreeSitter](https://github.com/ChimeHQ/SwiftTreeSitter),
[swift-cmark](https://github.com/swiftlang/swift-cmark),
[PostgresNIO](https://github.com/vapor/postgres-nio) ve
[MySQLNIO](https://github.com/vapor/mysql-nio).

## Lisans

[MIT](LICENSE) © 2026 Ahmet Şahin
