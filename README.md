# projekt-energia

End-to-end data pipeline w GCP: ceny i miks energii z API PSE + pogoda w Poznaniu → architektura medalionowa w BigQuery → rekomendacja, kiedy ładować flotę aut elektrycznych.

Opis biznesowy, architektura i harmonogram są w [KONSPEKT.md](KONSPEKT.md). Podział pracy na 4 osoby, krok po kroku: [ZADANIA.md](ZADANIA.md).

`deploy.sh` można uruchomić w całości albo krokami (`apis iam bucket bigquery functions scheduler queries`); każda osoba uruchamia swoje.

## Struktura

```
functions/
  ingest/            Cloud Run Function (HTTP): API -> landing zone w Cloud Storage
    sources.py       pobieranie z PSE i Open-Meteo (sama biblioteka standardowa)
    main.py          handler HTTP, zapis NDJSON do GCS
  load_bronze/       Cloud Run Function (Eventarc): plik w GCS -> bronze.raw_records
sql/
  00_setup.sql       datasety i tabele (partycje, klastry)
  pipeline.sql       bronze -> silver -> gold, przyrostowo (scheduled query co 3 h)
  data_quality.sql   testy ASSERT (scheduled query codziennie)
infra/
  deploy.sh          wdrożenie wszystkiego jednym poleceniem
  backfill.sh        pobranie historii od 2024-06-14
  lifecycle.json     reguła lifecycle dla bucketu
```

## Uruchomienie

1. Admin zakłada projekt GCP (konto z darmowym okresem próbnym), **ustawia budżet z alertami** i nadaje reszcie zespołu role w IAM.
2. W Cloud Shell:
   ```bash
   git clone <repo> && cd projekt-energia
   PROJECT_ID=twoj-projekt ./infra/deploy.sh
   ```
3. Pobranie historii (2,5 roku zajmie ok. 1–2 h; można zacząć od krótszego okresu, np. `2025-11-01`):
   ```bash
   PROJECT_ID=twoj-projekt ./infra/backfill.sh 2024-06-14
   ```
4. Po najbliższym przebiegu `energy-pipeline` (co 3 h, albo „Run now” w konsoli BigQuery → Scheduled queries) dane są w `gold`.
5. Looker Studio → Add data → BigQuery → dataset `gold`.

## Lokalny test pobierania (bez GCP)

```bash
cd functions/ingest && python3 sources.py 2026-11-13
```

## Jak to działa

| Kiedy | Co |
|---|---|
| 06:00 | Scheduler → `energy-ingest` z `date_offset=-1`: wszystkie źródła za wczoraj |
| 15:30 | Scheduler → `energy-ingest`: ceny (`rce-pln`) i prognoza pogody na jutro |
| nowy plik w `landing/` | Eventarc → `energy-load-bronze` → load job do `bronze.raw_records` |
| co 3 h | scheduled query `energy-pipeline`: MERGE do silver i przeliczenie gold tylko dla dni z nowymi danymi |
| 09:00 | scheduled query `energy-data-quality`: ASSERT-y; błąd → e-mail |

Ręcznie można też wrzucić plik `.ndjson` do `landing/<źródło>/business_date=YYYY-MM-DD/`, a dalej wszystko zadzieje się samo.

## Do pokazania na obronie (optymalizacja)

Uruchomcie to samo zapytanie na `bronze.raw_records` (pełny skan JSON) i na `silver.unit_generation` z filtrem daty i `power_plant = 'Karolin 2'`. Porównajcie „Bytes processed” w zakładce Job information. Drugi przykład: pełne przeliczenie silver vs. przebieg przyrostowy.

## Status / do zrobienia

- [x] Pobieranie z API przetestowane lokalnie (PSE z paginacją, Open-Meteo forecast i archive).
- [x] Logika obu funkcji przetestowana lokalnie z atrapami GCS i BigQuery.
- [ ] **SQL i `deploy.sh` nie były jeszcze uruchomione w GCP.** Pierwsze wdrożenie = pierwszy prawdziwy test; spodziewajcie się drobnych poprawek.
- [ ] Rozszyfrować pozostałe pola `his-wlk-cal` (`jg`, `jgw1`, `jnwrb`…) w opisie raportów PSE i ewentualnie dodać je do silver.
- [ ] Dashboard w Looker Studio.
- [ ] Rozszerzenie: najtańsze okno tylko w godzinach postoju floty (np. 18:00–06:00).
