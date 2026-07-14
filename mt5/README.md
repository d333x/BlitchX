# ProfitScalper v3.60 — Instant LOCK + predict

Каждая плюсовая позиция закрывается **сразу отдельно** (таймер 100мс). Корзина доливается без ожидания закрытия всех.

# ProfitScalper v3.60 — Forex + золото + база знаний

Фарм-цикл с выбором стороны по **свечам и структуре графика** (поглощение, пин/молот, HH/HL, импульс) + EMA.

Полный текст базы знаний: [`docs/BAZA_ZNANIY.md`](docs/BAZA_ZNANIY.md)  
Код оценки: [`Include/ChartKnowledge.mqh`](Include/ChartKnowledge.mqh)

## Что умеет

1. До **5 позиций × 0.10** на каждый символ (forex и золото отдельно)
2. Закрытие при плюсе: FX ≥ $0.30, золото ≥ $0.80
3. `FarmLoop` — открыл → закрыл плюс → снова
4. Авто-поиск золота (`XAUUSD` / `GOLD` / …)
5. **База знаний** в `DIR_AUTO`: score BUY/SELL по паттернам

## Установка

1. Скопировать в терминал:
   - `Experts/ProfitScalper.mq5` (+ `.ex5` если есть)
   - `Include/ChartKnowledge.mqh` → `MQL5/Include/` **или** держать относительный путь `../Include/`
2. Compile (F7) → на график → **Algo Trading ON**
3. `AlsoSymbols = XAUUSD`

## Ключевые настройки

| Параметр | По умолчанию | Смысл |
|---|---|---|
| `UseKnowledge` | true | Свечи/структура для стороны |
| `KnowledgeGap` | 2 | Мин. отрыв баллов BUY vs SELL |
| `Lot` / `GoldLot` | 0.10 | Лоты |
| `FarmLoop` | true | Непрерывный фарм |
| `AlsoSymbols` | XAUUSD | Доп. символы |

## Честно

Паттерны повышают вероятность стороны, **не гарантируют** прибыль. Сначала демо. Для 24/7 — Windows VPS.
