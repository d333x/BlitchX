//+------------------------------------------------------------------+
//|                                               ProfitScalper.mq5  |
//|  Анализ рынка → вход Buy/Sell при сильном сигнале → фиксация     |
//|  прибыли → повтор до остановки советника.                        |
//+------------------------------------------------------------------+
#property copyright "ProfitScalper"
#property version   "2.00"
#property description "Скальпер с анализом тренда, моментума и торговых сессий"

#include <Trade/Trade.mqh>

enum ENUM_TRADE_DIRECTION
  {
   DIR_BUY  = 0,  // Только Buy
   DIR_SELL = 1,  // Только Sell
   DIR_AUTO = 2   // Авто: лучший сигнал Buy vs Sell
  };

enum ENUM_PROFIT_MODE
  {
   PROFIT_MONEY  = 0, // Прибыль в деньгах депозита
   PROFIT_POINTS = 1  // Прибыль в пунктах
  };

enum ENUM_SESSION_MODE
  {
   SESSION_ALL     = 0, // Все сессии
   SESSION_BEST    = 1, // Только оптимальные (Лондон/NY + оверлап)
   SESSION_LONDON  = 2, // Лондон
   SESSION_NEWYORK = 3, // Нью-Йорк
   SESSION_ASIAN   = 4  // Азия
  };

input group "=== Торговля ==="
input ENUM_TRADE_DIRECTION InpDirection   = DIR_AUTO;      // Направление
input double               InpLot         = 0.01;          // Лот
input ENUM_PROFIT_MODE     InpProfitMode  = PROFIT_MONEY;  // Режим фиксации прибыли
input double               InpMinProfit   = 0.10;          // Мин. прибыль для закрытия
input int                  InpMagic       = 26071401;      // Magic number
input int                  InpDeviation   = 30;            // Проскальзывание (пункты)
input int                  InpPauseMs     = 500;           // Пауза после закрытия (мс)

input group "=== Анализ рынка ==="
input ENUM_TIMEFRAMES      InpTrendTF     = PERIOD_M15;    // ТФ тренда
input ENUM_TIMEFRAMES      InpSignalTF    = PERIOD_M5;     // ТФ сигнала
input int                  InpFastEMA     = 8;             // Быстрая EMA
input int                  InpSlowEMA     = 21;            // Медленная EMA
input int                  InpRSIPeriod   = 14;            // RSI период
input double               InpRSIBuyMax   = 65.0;          // Buy: RSI не выше
input double               InpRSISellMin  = 35.0;          // Sell: RSI не ниже
input int                  InpMinScore    = 4;             // Мин. score для входа (из 7)
input int                  InpScoreGap    = 2;             // Насколько Buy лучше Sell (и наоборот)

input group "=== Фильтры качества ==="
input bool                 InpUseSpreadFilter = true;      // Фильтр спреда
input int                  InpMaxSpreadPts    = 25;        // Макс. спред (пункты)
input bool                 InpUseATRFilter    = true;      // Фильтр волатильности ATR
input int                  InpATRPeriod       = 14;        // ATR период
input double               InpMinATRPoints    = 30.0;      // Мин. ATR (пункты)
input double               InpMaxATRPoints    = 500.0;     // Макс. ATR (пункты, 0=выкл)
input bool                 InpRequireCandle   = true;      // Нужна подтверждающая свеча

input group "=== Торговые сессии (серверное время брокера) ==="
input ENUM_SESSION_MODE    InpSessionMode = SESSION_BEST;  // Режим сессий
input int                  InpLondonStart = 8;             // Лондон старт (час)
input int                  InpLondonEnd   = 17;            // Лондон конец (час)
input int                  InpNYStart     = 13;            // NY старт (час)
input int                  InpNYEnd       = 22;            // NY конец (час)
input int                  InpAsiaStart   = 0;             // Азия старт (час)
input int                  InpAsiaEnd     = 9;             // Азия конец (час)

input group "=== Защита ==="
input bool                 InpUseStopLoss = true;          // Stop Loss
input int                  InpStopLossPts = 150;           // Stop Loss (пункты, 0=по ATR)
input double               InpATR_SL_Mult = 1.5;           // SL = ATR * множитель (если pts=0)
input bool                 InpCloseOnReverse = true;       // Закрыть, если анализ развернулся против
input bool                 InpMaxLossDay  = true;          // Лимит убытка за день
input double               InpMaxLossMoney = 50.0;         // Макс. убыток за день ($)

CTrade   trade;
int      g_ema_fast_trend = INVALID_HANDLE;
int      g_ema_slow_trend = INVALID_HANDLE;
int      g_ema_fast_sig   = INVALID_HANDLE;
int      g_ema_slow_sig   = INVALID_HANDLE;
int      g_rsi_handle     = INVALID_HANDLE;
int      g_atr_handle     = INVALID_HANDLE;

datetime g_day_start      = 0;
double   g_day_pnl        = 0.0;
bool     g_trading_paused = false;
ulong    g_last_close_ms  = 0;
datetime g_last_bar_time  = 0;
string   g_last_skip_reason = "";

struct MarketScore
  {
   int    buy;
   int    sell;
   string buy_reasons;
   string sell_reasons;
   double rsi;
   double atr_pts;
   double spread_pts;
   bool   trend_up;
   bool   trend_down;
   bool   session_ok;
   string session_name;
  };

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpFastEMA >= InpSlowEMA)
     {
      Print("Ошибка: Fast EMA должна быть меньше Slow EMA");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMinScore < 1 || InpMinScore > 7)
     {
      Print("Ошибка: MinScore должен быть от 1 до 7");
      return INIT_PARAMETERS_INCORRECT;
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   g_ema_fast_trend = iMA(_Symbol, InpTrendTF,  InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_ema_slow_trend = iMA(_Symbol, InpTrendTF,  InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_ema_fast_sig   = iMA(_Symbol, InpSignalTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_ema_slow_sig   = iMA(_Symbol, InpSignalTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_rsi_handle     = iRSI(_Symbol, InpSignalTF, InpRSIPeriod, PRICE_CLOSE);
   g_atr_handle     = iATR(_Symbol, InpSignalTF, InpATRPeriod);

   if(g_ema_fast_trend == INVALID_HANDLE || g_ema_slow_trend == INVALID_HANDLE ||
      g_ema_fast_sig   == INVALID_HANDLE || g_ema_slow_sig   == INVALID_HANDLE ||
      g_rsi_handle     == INVALID_HANDLE || g_atr_handle     == INVALID_HANDLE)
     {
      Print("Не удалось создать индикаторы");
      return INIT_FAILED;
     }

   g_day_start = DayStart();
   g_day_pnl   = 0.0;

   PrintFormat("ProfitScalper v2 | %s | lot=%.2f | minScore=%d | session=%d",
               _Symbol, InpLot, InpMinScore, (int)InpSessionMode);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_ema_fast_trend != INVALID_HANDLE) IndicatorRelease(g_ema_fast_trend);
   if(g_ema_slow_trend != INVALID_HANDLE) IndicatorRelease(g_ema_slow_trend);
   if(g_ema_fast_sig   != INVALID_HANDLE) IndicatorRelease(g_ema_fast_sig);
   if(g_ema_slow_sig   != INVALID_HANDLE) IndicatorRelease(g_ema_slow_sig);
   if(g_rsi_handle     != INVALID_HANDLE) IndicatorRelease(g_rsi_handle);
   if(g_atr_handle     != INVALID_HANDLE) IndicatorRelease(g_atr_handle);
   Print("ProfitScalper остановлен");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ResetDayIfNeeded();

   if(g_trading_paused)
      return;

   if(InpMaxLossDay && g_day_pnl <= -MathAbs(InpMaxLossMoney))
     {
      PrintFormat("Дневной лимит убытка: %.2f. Торговля остановлена.", g_day_pnl);
      g_trading_paused = true;
      return;
     }

   MarketScore score;
   if(!AnalyzeMarket(score))
      return;

   if(HasOurPosition())
     {
      TryCloseOnProfit();
      if(InpCloseOnReverse && HasOurPosition())
         TryCloseOnReverse(score);
      return;
     }

   if(g_last_close_ms > 0 && (GetTickCount64() - g_last_close_ms) < (ulong)InpPauseMs)
      return;

   // Новый вход только на новом баре сигнала — меньше шума
   datetime bar_time = iTime(_Symbol, InpSignalTF, 0);
   if(bar_time == 0)
      return;
   if(bar_time == g_last_bar_time)
      return;

   ENUM_ORDER_TYPE type;
   string reason;
   if(!PickEntry(score, type, reason))
     {
      if(reason != g_last_skip_reason)
        {
         g_last_skip_reason = reason;
         PrintFormat("Ожидание входа: %s | Buy=%d Sell=%d RSI=%.1f ATR=%.0f spread=%.0f session=%s",
                     reason, score.buy, score.sell, score.rsi, score.atr_pts,
                     score.spread_pts, score.session_name);
        }
      return;
     }

   g_last_bar_time = bar_time;
   OpenTrade(type, score, reason);
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if((long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic)
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT)
      return;

   g_day_pnl += HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
              + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
              + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
  }

//+------------------------------------------------------------------+
datetime DayStart()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
  }

//+------------------------------------------------------------------+
void ResetDayIfNeeded()
  {
   datetime start = DayStart();
   if(start == g_day_start)
      return;
   g_day_start = start;
   g_day_pnl = 0.0;
   g_trading_paused = false;
   g_last_skip_reason = "";
   Print("Новый день — P&L обнулён");
  }

//+------------------------------------------------------------------+
bool CopyBuf(const int handle, const int buffer, const int start, const int count, double &out[])
  {
   ArraySetAsSeries(out, true);
   return CopyBuffer(handle, buffer, start, count, out) == count;
  }

//+------------------------------------------------------------------+
bool IsHourInRange(const int hour, const int start_h, const int end_h)
  {
   if(start_h == end_h)
      return true;
   if(start_h < end_h)
      return (hour >= start_h && hour < end_h);
   // Через полночь
   return (hour >= start_h || hour < end_h);
  }

//+------------------------------------------------------------------+
bool CheckSession(string &name, int &session_bonus_buy, int &session_bonus_sell)
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   const int h = dt.hour;

   const bool london = IsHourInRange(h, InpLondonStart, InpLondonEnd);
   const bool ny     = IsHourInRange(h, InpNYStart, InpNYEnd);
   const bool asia   = IsHourInRange(h, InpAsiaStart, InpAsiaEnd);
   const bool overlap = london && ny; // лучшая ликвидность

   session_bonus_buy  = 0;
   session_bonus_sell = 0;

   if(overlap)
     {
      name = "London+NY overlap";
      session_bonus_buy  = 1;
      session_bonus_sell = 1;
     }
   else if(london)
     {
      name = "London";
      session_bonus_buy  = 1;
      session_bonus_sell = 1;
     }
   else if(ny)
     {
      name = "New York";
      session_bonus_buy  = 1;
      session_bonus_sell = 1;
     }
   else if(asia)
     {
      name = "Asian";
      // Азия чаще спокойнее — бонус меньше, но разрешаем
     }
   else
     {
      name = "Off-hours";
     }

   switch(InpSessionMode)
     {
      case SESSION_ALL:     return true;
      case SESSION_BEST:    return (overlap || london || ny);
      case SESSION_LONDON:  return london;
      case SESSION_NEWYORK: return ny;
      case SESSION_ASIAN:   return asia;
     }
   return true;
  }

//+------------------------------------------------------------------+
bool AnalyzeMarket(MarketScore &s)
  {
   s.buy = 0;
   s.sell = 0;
   s.buy_reasons  = "";
   s.sell_reasons = "";
   s.rsi = 0.0;
   s.atr_pts = 0.0;
   s.spread_pts = 0.0;
   s.trend_up = false;
   s.trend_down = false;
   s.session_ok = false;
   s.session_name = "";

   double fast_t[], slow_t[], fast_s[], slow_s[], rsi[], atr[];
   if(!CopyBuf(g_ema_fast_trend, 0, 0, 3, fast_t)) return false;
   if(!CopyBuf(g_ema_slow_trend, 0, 0, 3, slow_t)) return false;
   if(!CopyBuf(g_ema_fast_sig,   0, 0, 3, fast_s)) return false;
   if(!CopyBuf(g_ema_slow_sig,   0, 0, 3, slow_s)) return false;
   if(!CopyBuf(g_rsi_handle,     0, 0, 3, rsi))    return false;
   if(!CopyBuf(g_atr_handle,     0, 0, 3, atr))    return false;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return false;

   s.rsi        = rsi[0];
   s.atr_pts    = atr[0] / point;
   s.spread_pts = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / point;
   s.trend_up   = (fast_t[0] > slow_t[0] && fast_t[0] > fast_t[1]);
   s.trend_down = (fast_t[0] < slow_t[0] && fast_t[0] < fast_t[1]);

   int sess_buy = 0, sess_sell = 0;
   s.session_ok = CheckSession(s.session_name, sess_buy, sess_sell);

   // --- 1) Тренд старшего ТФ ---
   if(fast_t[0] > slow_t[0])
     {
      s.buy++;
      s.buy_reasons += "trendUp ";
     }
   if(fast_t[0] < slow_t[0])
     {
      s.sell++;
      s.sell_reasons += "trendDown ";
     }

   // --- 2) Импульс тренда (угол EMA) ---
   if(s.trend_up)
     {
      s.buy++;
      s.buy_reasons += "emaRising ";
     }
   if(s.trend_down)
     {
      s.sell++;
      s.sell_reasons += "emaFalling ";
     }

   // --- 3) Сигнальный ТФ: EMA alignment ---
   if(fast_s[0] > slow_s[0])
     {
      s.buy++;
      s.buy_reasons += "sigBull ";
     }
   if(fast_s[0] < slow_s[0])
     {
      s.sell++;
      s.sell_reasons += "sigBear ";
     }

   // --- 4) Пересечение / ускорение на сигнальном ТФ ---
   const bool bull_cross = (fast_s[1] <= slow_s[1] && fast_s[0] > slow_s[0]);
   const bool bear_cross = (fast_s[1] >= slow_s[1] && fast_s[0] < slow_s[0]);
   if(bull_cross || (fast_s[0] > slow_s[0] && fast_s[0] - fast_s[1] > slow_s[0] - slow_s[1]))
     {
      s.buy++;
      s.buy_reasons += "momentumUp ";
     }
   if(bear_cross || (fast_s[0] < slow_s[0] && fast_s[1] - fast_s[0] > slow_s[1] - slow_s[0]))
     {
      s.sell++;
      s.sell_reasons += "momentumDown ";
     }

   // --- 5) RSI зона ---
   if(s.rsi < InpRSIBuyMax && s.rsi > 40.0)
     {
      s.buy++;
      s.buy_reasons += "rsiOk ";
     }
   if(s.rsi > InpRSISellMin && s.rsi < 60.0)
     {
      s.sell++;
      s.sell_reasons += "rsiOk ";
     }
   // Перепроданность / перекупленность как доп. точка разворота только вместе с трендом не даём
   if(s.rsi < 30.0 && fast_t[0] > slow_t[0])
     {
      s.buy++;
      s.buy_reasons += "rsiOversold ";
     }
   if(s.rsi > 70.0 && fast_t[0] < slow_t[0])
     {
      s.sell++;
      s.sell_reasons += "rsiOverbought ";
     }

   // --- 6) Подтверждающая свеча ---
   double open1  = iOpen(_Symbol, InpSignalTF, 1);
   double close1 = iClose(_Symbol, InpSignalTF, 1);
   double high1  = iHigh(_Symbol, InpSignalTF, 1);
   double low1   = iLow(_Symbol, InpSignalTF, 1);
   const double body = MathAbs(close1 - open1);
   const double range = high1 - low1;
   const bool bull_candle = (close1 > open1 && range > 0 && body / range >= 0.45);
   const bool bear_candle = (close1 < open1 && range > 0 && body / range >= 0.45);

   if(bull_candle)
     {
      s.buy++;
      s.buy_reasons += "bullCandle ";
     }
   if(bear_candle)
     {
      s.sell++;
      s.sell_reasons += "bearCandle ";
     }

   // --- 7) Бонус оптимальной сессии ---
   if(sess_buy > 0)
     {
      s.buy += sess_buy;
      s.buy_reasons += "session ";
     }
   if(sess_sell > 0)
     {
      s.sell += sess_sell;
      s.sell_reasons += "session ";
     }

   // Цена относительно EMA сигнала
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid > fast_s[0] && bid > slow_s[0])
     {
      s.buy++;
      s.buy_reasons += "priceAboveEMA ";
     }
   if(bid < fast_s[0] && bid < slow_s[0])
     {
      s.sell++;
      s.sell_reasons += "priceBelowEMA ";
     }

   return true;
  }

//+------------------------------------------------------------------+
bool FiltersPass(const MarketScore &s, string &reason)
  {
   if(!s.session_ok)
     {
      reason = "вне оптимальной сессии (" + s.session_name + ")";
      return false;
     }

   if(InpUseSpreadFilter && s.spread_pts > (double)InpMaxSpreadPts)
     {
      reason = StringFormat("широкий спред %.0f > %d", s.spread_pts, InpMaxSpreadPts);
      return false;
     }

   if(InpUseATRFilter)
     {
      if(s.atr_pts < InpMinATRPoints)
        {
         reason = StringFormat("низкая волатильность ATR %.0f", s.atr_pts);
         return false;
        }
      if(InpMaxATRPoints > 0.0 && s.atr_pts > InpMaxATRPoints)
        {
         reason = StringFormat("слишком высокая волатильность ATR %.0f", s.atr_pts);
         return false;
        }
     }

   return true;
  }

//+------------------------------------------------------------------+
bool PickEntry(const MarketScore &s, ENUM_ORDER_TYPE &type, string &reason)
  {
   if(!FiltersPass(s, reason))
      return false;

   const bool buy_ok  = (s.buy  >= InpMinScore && s.buy  >= s.sell + InpScoreGap);
   const bool sell_ok = (s.sell >= InpMinScore && s.sell >= s.buy  + InpScoreGap);

   if(InpRequireCandle)
     {
      // candle уже учтена в score; дополнительно требуем не входить против сильной свечи
      double open1  = iOpen(_Symbol, InpSignalTF, 1);
      double close1 = iClose(_Symbol, InpSignalTF, 1);
      if(buy_ok && close1 < open1)
        {
         // ослабляем только если нет явного трендового преимущества
         if(s.buy < s.sell + InpScoreGap + 1)
           {
            reason = "Buy отклонён: медвежья свеча";
            return false;
           }
        }
      if(sell_ok && close1 > open1)
        {
         if(s.sell < s.buy + InpScoreGap + 1)
           {
            reason = "Sell отклонён: бычья свеча";
            return false;
           }
        }
     }

   if(InpDirection == DIR_BUY)
     {
      if(!buy_ok)
        {
         reason = StringFormat("Buy слаб: score %d/%d (Sell=%d)", s.buy, InpMinScore, s.sell);
         return false;
        }
      type = ORDER_TYPE_BUY;
      reason = "BUY | " + s.buy_reasons;
      return true;
     }

   if(InpDirection == DIR_SELL)
     {
      if(!sell_ok)
        {
         reason = StringFormat("Sell слаб: score %d/%d (Buy=%d)", s.sell, InpMinScore, s.buy);
         return false;
        }
      type = ORDER_TYPE_SELL;
      reason = "SELL | " + s.sell_reasons;
      return true;
     }

   // AUTO — только если одно направление явно сильнее
   if(buy_ok && !sell_ok)
     {
      type = ORDER_TYPE_BUY;
      reason = "AUTO BUY | " + s.buy_reasons;
      return true;
     }
   if(sell_ok && !buy_ok)
     {
      type = ORDER_TYPE_SELL;
      reason = "AUTO SELL | " + s.sell_reasons;
      return true;
     }
   if(buy_ok && sell_ok)
     {
      if(s.buy > s.sell)
        {
         type = ORDER_TYPE_BUY;
         reason = "AUTO BUY (сильнее) | " + s.buy_reasons;
         return true;
        }
      if(s.sell > s.buy)
        {
         type = ORDER_TYPE_SELL;
         reason = "AUTO SELL (сильнее) | " + s.sell_reasons;
         return true;
        }
      reason = StringFormat("ничья Buy=%d Sell=%d", s.buy, s.sell);
      return false;
     }

   reason = StringFormat("нет преимущества Buy=%d Sell=%d (нужно >=%d и gap>=%d)",
                         s.buy, s.sell, InpMinScore, InpScoreGap);
   return false;
  }

//+------------------------------------------------------------------+
bool HasOurPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
bool SelectOurPosition(ulong &ticket)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      return true;
     }
   ticket = 0;
   return false;
  }

//+------------------------------------------------------------------+
double PositionProfitMoney()
  {
   return PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
  }

//+------------------------------------------------------------------+
double PositionProfitPoints()
  {
   double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   long   type       = PositionGetInteger(POSITION_TYPE);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return 0.0;
   if(type == POSITION_TYPE_BUY)
      return (bid - open_price) / point;
   return (open_price - ask) / point;
  }

//+------------------------------------------------------------------+
bool IsProfitReady()
  {
   if(InpProfitMode == PROFIT_MONEY)
      return PositionProfitMoney() >= InpMinProfit;
   return PositionProfitPoints() >= InpMinProfit;
  }

//+------------------------------------------------------------------+
void TryCloseOnProfit()
  {
   ulong ticket;
   if(!SelectOurPosition(ticket))
      return;
   if(!IsProfitReady())
      return;

   double profit = PositionProfitMoney();
   double points = PositionProfitPoints();
   if(trade.PositionClose(ticket, InpDeviation))
     {
      g_last_close_ms = GetTickCount64();
      PrintFormat("FIX PROFIT #%I64u | %.2f | %.1f pts", ticket, profit, points);
     }
   else
      PrintFormat("Ошибка закрытия #%I64u: %d %s",
                  ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
void TryCloseOnReverse(const MarketScore &s)
  {
   ulong ticket;
   if(!SelectOurPosition(ticket))
      return;

   long type = PositionGetInteger(POSITION_TYPE);
   bool against = false;

   if(type == POSITION_TYPE_BUY)
      against = (s.sell >= InpMinScore && s.sell >= s.buy + InpScoreGap && s.trend_down);
   else
      against = (s.buy  >= InpMinScore && s.buy  >= s.sell + InpScoreGap && s.trend_up);

   if(!against)
      return;

   // Не режем в сильном плавающем плюсе — его закроет фиксация прибыли
   if(IsProfitReady())
      return;

   double profit = PositionProfitMoney();
   if(trade.PositionClose(ticket, InpDeviation))
     {
      g_last_close_ms = GetTickCount64();
      PrintFormat("REVERSE EXIT #%I64u | pnl=%.2f | Buy=%d Sell=%d",
                  ticket, profit, s.buy, s.sell);
     }
  }

//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step_lot <= 0.0)
      step_lot = 0.01;

   lot = MathFloor(lot / step_lot + 1e-12) * step_lot;
   if(lot < min_lot) lot = min_lot;
   if(lot > max_lot) lot = max_lot;
   return NormalizeDouble(lot, 2);
  }

//+------------------------------------------------------------------+
double CalcStopLoss(const ENUM_ORDER_TYPE type, const MarketScore &s)
  {
   if(!InpUseStopLoss)
      return 0.0;

   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double sl_pts = (double)InpStopLossPts;

   if(InpStopLossPts <= 0)
      sl_pts = MathMax(s.atr_pts * InpATR_SL_Mult, InpMinATRPoints);

   if(type == ORDER_TYPE_BUY)
      return NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID) - sl_pts * point, digits);
   return NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_ASK) + sl_pts * point, digits);
  }

//+------------------------------------------------------------------+
void OpenTrade(const ENUM_ORDER_TYPE type, const MarketScore &s, const string reason)
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      return;

   double lot = NormalizeLot(InpLot);
   double sl  = CalcStopLoss(type, s);
   string comment = (type == ORDER_TYPE_BUY) ? "PS Buy" : "PS Sell";

   bool ok = (type == ORDER_TYPE_BUY)
             ? trade.Buy(lot, _Symbol, 0.0, sl, 0.0, comment)
             : trade.Sell(lot, _Symbol, 0.0, sl, 0.0, comment);

   if(ok)
      PrintFormat("OPEN %s | lot=%.2f | BuyScore=%d SellScore=%d RSI=%.1f ATR=%.0f | %s | %s",
                  type == ORDER_TYPE_BUY ? "BUY" : "SELL",
                  lot, s.buy, s.sell, s.rsi, s.atr_pts, s.session_name, reason);
   else
      PrintFormat("Ошибка открытия: %d %s",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }
//+------------------------------------------------------------------+
