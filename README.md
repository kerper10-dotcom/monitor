# Njuskalo Monitor (Main Bot)

Automatski monitor za njuskalo.hr.

Prati:
- Toyota Yaris Hybrid (2020+)
- Mazda CX-30 / CX-5
- Građevinska zemljišta Zadar + okolica
- Stanovi Zagreb + Zagrebačka županija

Osim novih oglasa, prati i cijene na listi spremljenih oglasa (`saved_ads.json`).

## Pokretanje
Radi preko **GitHub Actions** (public repo = unlimited besplatnih minuta).

- Cron: `5 * * * *` (svaki sat u :05)
- Ručno: GitHub → Actions → Run workflow

## Konfiguracija
Samo preko GitHub Secrets:
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`

## Lokalno (samo za dev)
```bash
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
playwright install chromium --with-deps
python monitor.py
```

**Nikad** ne stavljaj tokene u kod ili u commit.

## Baza
- `njuskalo.db` — vidjeni oglasi
- `saved_ads.json` — lista za praćenje cijena (sinkronizira se u bazu)

GitHub Actions automatski commit-a promjene baze natrag u repo.
