# Değişiklik günlüğü

Tezgah'taki önemli değişiklikler bu dosyada tutulur. Biçim [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)'a
dayanır, sürümler [Semantic Versioning](https://semver.org/) ile numaralanır.

## [Yayınlanmadı]

### Eklendi

- **Ajanlar kendi başına yürüsün** ayarı (varsayılan açık): ajanların klasörüne önceden güvenilir; kullanım limiti dolan
  ajan sıfırlanmayı bekleyip kendiliğinden devam eder, Telegram'a haber verilir; bekleme orkestranın süre sınırına sayılmaz.

### Düzeltildi

- Veritabanı parolası Keychain'den her bağlantıda yeniden okunmuyor; ajan sorgularında macOS'un parola sorması bitti.
  `make app`, Keychain'de bir Apple Development sertifikası varsa onunla imzalar; "Her Zaman İzin Ver" derlemeler arasında
  kalıcı olur.
- Tam yetkili Claude oturumları Claude Code'un "Bypass Permissions" uyarısında beklemiyor; Codex güncelleme ekranında
  beklemiyor.

## [1.0.0] - 2026-10-18

İlk açık kaynak sürüm.

### Eklendi

- **Orkestra:** panodaki kart planlanır, kendi worktree'sinde geliştirilir, bir ya da birden çok ajan tarafından gözden
  geçirilir ve birleştirilir. Sırayla yürütme, koşu sayfası, takılan kartlar için Devam Et / Baştan Başlat, süre ve tur
  sınırları, çakışma çözümü, birleşince push.
- **Lider ajan:** Claude ya da Codex oturumu işi `agent_spawn`, `agent_wait`, `agent_send`, `agent_merge`, `agent_stop`
  ve `agent_list` ile başka ajanlara bölebilir.
- **Claude Code ve Codex oturumları:** sohbet görünümü, native composer, durum takibi, onaylar, bağlam ve plan limitleri,
  Remote Control, prompt önerileri, onaysız çalışma seçeneği.
- **Tezgah araçları (MCP):** tarayıcı, iOS Simülatörü, pano, veritabanı, terminal ve editör ajanlara açık.
- **Telegram:** bildirimler, onaylar ve komutlarla telefondan takip.
- **Proje panosu:** kanban, kartı kendi worktree'sinde bir ajana verme.
- **Editör, terminal ve git:** tree-sitter ile 40+ dil, hızlı açma, projede arama, komut paleti, Markdown önizleme,
  Make menüsü, git paneli, canlı dosya izleme.
- **Veritabanı:** PostgreSQL, MySQL / MariaDB ve SQLite; SQL tamamlama, tablo düzenleme, EXPLAIN, sorgu geçmişi,
  SSH tüneli.

[Yayınlanmadı]: https://github.com/ahmetsahin83/tezgah/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/ahmetsahin83/tezgah/releases/tag/v1.0.0
