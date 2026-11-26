# Respool

Claude Code sohbetleriniz için ekranın sağ kenarından açılan bir panel. Bütün projelerinizdeki
sohbetleri tek yerde gösterir, içlerinde arar ve tıklayınca sohbeti bulunduğu yerde açar.

## Ne yapar

- **Arama.** Sohbet adlarında ve konuşmaların içinde arar; eşleşen yerden bir alıntı gösterir.
- **Projeler.** Aynı deponun farklı klasörlerdeki kopyalarını tek proje altında toplar
  (git remote adresine göre). Projeleri elle birleştirebilir ve yeniden adlandırabilirsiniz.
- **Sabitleme ve görevler.** Sık döndüğünüz sohbetleri sabitleyin; her birine yapılacaklar ekleyin.
- **Etiketler.** Sohbetlere renkli etiket verin; aramanın altındaki etikete tıklayınca yalnızca
  o etiketteki sohbetler listelenir.
- **Hesaplar.** Ayarlar'dan açılır, varsayılan olarak kapalıdır. Birden fazla organizasyonunuz
  varsa üstteki seçiciyle listeyi birine daraltın.
  Claude uygulamasının o an açık olmayan organizasyonundaki bir sohbet oradan açılamaz;
  Respool bunu söyler, hesabı Claude'da siz değiştirirsiniz.
- **Canlı durum.** Açık sohbetlerde Claude çalışıyorsa bir gösterge, sıra sizdeyse bir nokta görünür.
- **Açma.** Claude uygulamasındaki sohbet orada açılır. Terminalde açık olan sohbetin terminali
  öne gelir. Kapalı bir terminal sohbeti yeni bir terminalde sürdürülür.

## Kullanım

| Tuş | İşlev |
|---|---|
| `⌥⇧Space` | Paneli aç veya kapat (Ayarlar'dan değiştirilebilir) |
| `↑` `↓` | Sohbetler arasında gez |
| `↩` | Seçili sohbeti aç |
| `esc` | Aramayı temizle, sonra paneli kapat |

Bir sohbetin üzerine gelince sabitleme düğmesi, sabitlenmiş sohbette görev ekleme düğmesi çıkar.
Diğer işlemler sağ tık menüsünde.

## Derleme

```bash
./scripts/install.sh
```

Bu komut uygulamayı derler, `/Applications/Respool.app` konumuna kopyalar ve başlatır. Yalnızca
derlemek için `./scripts/bundle.sh` çalıştırın; sonuç `build/Respool.app` içinde olur. Kısayol,
girişte başlatma ve hesap seçici panelin `…` menüsündeki Ayarlar sayfasındadır.

macOS 14 ve üstü, Xcode komut satırı araçları gerekir.

## Veriler

Respool, Claude Code dosyalarını yalnızca okur; hiçbirini değiştirmez.

| Kaynak | Ne için |
|---|---|
| `~/.claude/projects/**/*.jsonl` | Sohbet adları, tarihleri ve aranabilir metin |
| `~/.claude/sessions/*.json` | Hangi sohbetin şu an açık olduğu ve durumu |
| `~/Library/Application Support/Claude/claude-code-sessions` | Claude uygulamasındaki sohbetin bağlantısı |

Bu dosyaların biçimi Claude Code'a aittir ve sürümler arasında değişebilir; Respool 2.1.332 ile denendi.
Dizin, sabitlemeler ve görevler `~/Library/Application Support/Respool/respool.db` içinde durur.

## Geliştirme araçları

```bash
.build/release/Respool --index --query "aranan ifade"          # dizini güncelle, aramayı dene
.build/release/Respool --snapshot panel.png --dark             # paneli bir görüntüye çiz
RESPOOL_DB=/tmp/test.db .build/release/Respool --selftest          # sabitleme ve görev testleri
```
