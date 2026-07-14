//+------------------------------------------------------------------+
//|                                               ProfitScalper.mq5  |
//|  Profit Engine v3 — вход по сильному тренду, риск %, TP/SL,      |
//|  break-even и trailing. Без гарантий прибыли.                    |
//+------------------------------------------------------------------+
#property copyright "ProfitScalper"
#property version   "3.20"
#property description "Постоянный фарм: 5x0.1, закрыл плюс → снова открыл"

#include <Trade/Trade.mqh>

enum ENUM_TRADE_DIRECTION
  {
   DIR_BUY  = 0,
   DIR_SELL = 1,
   DIR_AUTO = 2
  };

enum ENUM_SESSION_MODE
  {
   SESSION_ALL     = 0,
   SESSION_BEST    = 1, // Лондон + NY + оверлап
   SESSION_LONDON  = 2,
   SESSION_NEWYORK = 3,
   SESSION_ASIAN   = 4
  };

enum ENUM_LOT_MODE
  {
   LOT_FIXED = 0, // Фиксированный лот
   LOT_RISK  = 1  // Лот от % риска на сделку
  };

input group "=== Торговля ==="
input ENUM_TRADE_DIRECTION InpDirection = DIR_AUTO;
input ENUM_LOT_MODE        InpLotMode   = LOT_FIXED;
input double               InpLot       = 0.10;      // Лот (минимум 0.1)
input double               InpRiskPercent = 1.0;     // Риск на сделку, % депозита
input int                  InpMagic     = 26071403;
input int                  InpDeviation = 30;
input int                  InpMaxPositions = 5;      // Сколько позиций держать одновременно
input int                  InpBasketOpen = 5;        // Сколько открывать за один заход
input int                  InpMaxTradesDay = 200;    // Макс. сделок за день
input bool                 InpFarmLoop = true;       // Постоянный цикл: закрыл → снова открыл
input int                  InpFarmCooldownMs = 800;  // Пауза перед новым заходом (мс)

input group "=== Фиксация прибыли ==="
input double               InpMinProfitMoney = 0.30; // Закрыть сделку при плюсе >= $
input bool                 InpCloseOnProfit  = true; // Закрывать сразу при плюсе
input double               InpRewardRisk = 1.5;      // TP = SL * R (страховка)
input bool                 InpUseBreakEven = true;
input double               InpBE_R       = 0.6;
input double               InpBE_OffsetPts = 3.0;
input bool                 InpUseTrailing = true;
input double               InpTrailStart_R = 0.8;
input double               InpTrailATR_Mult = 0.8;

input group "=== Анализ ==="
input ENUM_TIMEFRAMES      InpTrendTF   = PERIOD_H1;
input ENUM_TIMEFRAMES      InpSignalTF  = PERIOD_M15;
input int                  InpFastEMA   = 20;
input int                  InpSlowEMA   = 50;
input int                  InpRSIPeriod = 14;
input int                  InpADXPeriod = 14;
input double               InpMinADX    = 15.0;      // Минимальная сила тренда
input int                  InpMinScore  = 3;
input int                  InpScoreGap  = 1;

input group "=== Фильтры ==="
input bool                 InpUseSpreadFilter = true;
input int                  InpMaxSpreadPts    = 20;
input int                  InpATRPeriod       = 14;
input double               InpATR_SL_Mult     = 1.8; // Stop = ATR * mult
input double               InpMinATRPoints    = 40.0;
input double               InpMaxATRPoints    = 800.0;
input bool                 InpPullbackEntry   = true; // Вход на откате к EMA

input group "=== Сессии (время сервера брокера) ==="
input ENUM_SESSION_MODE    InpSessionMode = SESSION_ALL;
input int                  InpLondonStart = 8;
input int                  InpLondonEnd   = 17;
input int                  InpNYStart     = 13;
input int                  InpNYEnd       = 22;
input int                  InpAsiaStart   = 0;
input int                  InpAsiaEnd     = 9;

input group "=== Защита капитала ==="
input bool                 InpMaxLossDay   = true;
input double               InpMaxLossMoney = 50.0;
input bool                 InpMaxLossPct   = true;
input double               InpMaxLossPercent = 3.0;  // Стоп дня от баланса на старт дня
input bool                 InpCloseOnWeakTrend = true; // Выход если ADX/тренд ослаб и в минусе

CTrade trade;

int g_ema_fast_trend = INVALID_HANDLE;
int g_ema_slow_trend = INVALID_HANDLE;
int g_ema_fast_sig   = INVALID_HANDLE;
int g_ema_slow_sig   = INVALID_HANDLE;
int g_rsi_handle     = INVALID_HANDLE;
int g_atr_handle     = INVALID_HANDLE;
int g_adx_handle     = INVALID_HANDLE;

datetime g_day_start = 0;
double   g_day_pnl = 0.0;
double   g_day_start_balance = 0.0;
bool     g_trading_paused = false;
datetime g_last_bar_time = 0;
int      g_trades_today = 0;
string   g_last_skip = "";
ulong    g_last_farm_ms = 0;
ENUM_ORDER_TYPE g_last_farm_dir = ORDER_TYPE_SELL;
bool     g_have_farm_dir = false;

struct MarketScore
  {
   int    buy;
   int    sell;
   string buy_reasons;
   string sell_reasons;
   double rsi;
   double atr_pts;
   double spread_pts;
   double adx;
   bool   trend_up;
   bool   trend_down;
   bool   session_ok;
   string session_name;
   double pullback_buy;  // насколько близко к EMA (0..1 качество)
   double pullback_sell;
  };

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpFastEMA >= InpSlowEMA)
     {
      Print("Fast EMA < Slow EMA требуется");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRewardRisk < 1.2)
     {
      Print("RewardRisk слишком мал (<1.2) — стратегия будет иметь отрицательное матожидание");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 5.0)
     {
      Print("RiskPercent должен быть в диапазоне 0.01..5");
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
   g_adx_handle     = iADX(_Symbol, InpTrendTF, InpADXPeriod);

   if(g_ema_fast_trend == INVALID_HANDLE || g_ema_slow_trend == INVALID_HANDLE ||
      g_ema_fast_sig == INVALID_HANDLE || g_ema_slow_sig == INVALID_HANDLE ||
      g_rsi_handle == INVALID_HANDLE || g_atr_handle == INVALID_HANDLE ||
      g_adx_handle == INVALID_HANDLE)
     {
      Print("Ошибка создания индикаторов");
      return INIT_FAILED;
     }

   g_day_start = DayStart();
   g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_day_pnl = 0.0;
   g_trades_today = 0;

   PrintFormat("ProfitScalper v3.20 FARM | %s | lot=%.2f | basket=%d | lock>=$%.2f | loop=%s",
               _Symbol, InpLot, InpBasketOpen, InpMinProfitMoney, InpFarmLoop ? "ON" : "off");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(g_ema_fast_trend);
   IndicatorRelease(g_ema_slow_trend);
   IndicatorRelease(g_ema_fast_sig);
   IndicatorRelease(g_ema_slow_sig);
   IndicatorRelease(g_rsi_handle);
   IndicatorRelease(g_atr_handle);
   IndicatorRelease(g_adx_handle);
   Comment("");
   Print("ProfitScalper v3 остановлен");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ResetDayIfNeeded();
   UpdatePanel();

   if(g_trading_paused)
      return;

   if(DayRiskHit())
     {
      g_trading_paused = true;
      PrintFormat("Дневной риск исчерпан: dayPnL=%.2f. Торговля стоп.", g_day_pnl);
      return;
     }

   MarketScore score;
   if(!AnalyzeMarket(score))
      return;

   // Сначала фиксируем плюс по всем нашим позициям
   ManageAllPositions(score);

   const int open_now = CountOurPositions();
   if(open_now >= InpMaxPositions)
      return;

   if(g_trades_today >= InpMaxTradesDay)
      return;

   // Фарм-цикл: ждём пока все закроются, потом снова полный basket
   if(InpFarmLoop)
     {
      if(open_now > 0)
         return; // пока есть позиции — только управляем/фиксируем плюс

      if(g_last_farm_ms > 0 &&
         (GetTickCount64() - g_last_farm_ms) < (ulong)MathMax(InpFarmCooldownMs, 200))
         return;

      string filt_reason;
      if(!FarmFiltersPass(score, filt_reason))
        {
         if(filt_reason != g_last_skip)
           {
            g_last_skip = filt_reason;
            PrintFormat("Farm wait: %s", filt_reason);
           }
         return;
        }

      ENUM_ORDER_TYPE type;
      string reason;
      ResolveFarmDirection(score, type, reason);

      int basket = MathMin(InpBasketOpen, InpMaxPositions);
      if(basket < 1)
         basket = 1;

      int opened = OpenBasket(type, score, reason, basket);
      if(opened > 0)
        {
         g_last_farm_ms = GetTickCount64();
         g_last_farm_dir = type;
         g_have_farm_dir = true;
         PrintFormat("FARM cycle: открыто %d | %s", opened, reason);
        }
      return;
     }

   // Старый режим (по сигналу на новом баре)
   datetime bar = iTime(_Symbol, InpSignalTF, 0);
   if(bar == 0 || bar == g_last_bar_time)
      return;

   ENUM_ORDER_TYPE type;
   string reason;
   if(!PickEntry(score, type, reason))
     {
      if(reason != g_last_skip)
        {
         g_last_skip = reason;
         PrintFormat("Ждём: %s | Buy=%d Sell=%d ADX=%.1f ATR=%.0f %s",
                     reason, score.buy, score.sell, score.adx, score.atr_pts, score.session_name);
        }
      return;
     }

   g_last_bar_time = bar;
   int can_open = InpMaxPositions - open_now;
   int basket = MathMin(InpBasketOpen, can_open);
   if(basket < 1) basket = 1;
   OpenBasket(type, score, reason, basket);
  }

//+------------------------------------------------------------------+
bool FarmFiltersPass(const MarketScore &s, string &reason)
  {
   // В фарм-режиме почти не стопаем — только совсем широкий спред
   if(InpUseSpreadFilter && s.spread_pts > (double)MathMax(InpMaxSpreadPts * 3, 60))
     {
      reason = StringFormat("спред слишком широкий %.0f", s.spread_pts);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
void ResolveFarmDirection(const MarketScore &s, ENUM_ORDER_TYPE &type, string &reason)
  {
   if(InpDirection == DIR_BUY)
     { type = ORDER_TYPE_BUY; reason = "FARM BUY fixed"; return; }
   if(InpDirection == DIR_SELL)
     { type = ORDER_TYPE_SELL; reason = "FARM SELL fixed"; return; }

   // Авто: по score/тренду; если равно — повтор последнего направления
   if(s.buy > s.sell && s.trend_up)
     { type = ORDER_TYPE_BUY; reason = "FARM AUTO buy"; return; }
   if(s.sell > s.buy && s.trend_down)
     { type = ORDER_TYPE_SELL; reason = "FARM AUTO sell"; return; }
   if(s.trend_up)
     { type = ORDER_TYPE_BUY; reason = "FARM trend up"; return; }
   if(s.trend_down)
     { type = ORDER_TYPE_SELL; reason = "FARM trend down"; return; }
   if(g_have_farm_dir)
     {
      type = g_last_farm_dir;
      reason = (type == ORDER_TYPE_BUY) ? "FARM last BUY" : "FARM last SELL";
      return;
     }
   type = ORDER_TYPE_SELL;
   reason = "FARM default SELL";
  }

//+------------------------------------------------------------------+
int OpenBasket(const ENUM_ORDER_TYPE type, const MarketScore &s, const string reason, const int basket)
  {
   int opened = 0;
   for(int i = 0; i < basket; i++)
     {
      if(g_trades_today >= InpMaxTradesDay)
         break;
      if(CountOurPositions() >= InpMaxPositions)
         break;
      if(OpenTrade(type, s, reason + StringFormat(" #%d", i + 1)))
        {
         g_trades_today++;
         opened++;
        }
      else
         break;
     }
   return opened;
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
   g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_trading_paused = false;
   g_trades_today = 0;
   g_last_skip = "";
   Print("Новый день — лимиты обновлены");
  }

//+------------------------------------------------------------------+
bool DayRiskHit()
  {
   if(InpMaxLossDay && g_day_pnl <= -MathAbs(InpMaxLossMoney))
      return true;
   if(InpMaxLossPct && g_day_start_balance > 0.0)
     {
      double limit = g_day_start_balance * InpMaxLossPercent / 100.0;
      if(g_day_pnl <= -limit)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
bool CopyBuf(const int handle, const int buffer, const int count, double &out[])
  {
   ArraySetAsSeries(out, true);
   return CopyBuffer(handle, buffer, 0, count, out) == count;
  }

//+------------------------------------------------------------------+
bool IsHourInRange(const int hour, const int start_h, const int end_h)
  {
   if(start_h == end_h) return true;
   if(start_h < end_h)  return (hour >= start_h && hour < end_h);
   return (hour >= start_h || hour < end_h);
  }

//+------------------------------------------------------------------+
bool CheckSession(string &name)
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   const int h = dt.hour;
   const bool london = IsHourInRange(h, InpLondonStart, InpLondonEnd);
   const bool ny     = IsHourInRange(h, InpNYStart, InpNYEnd);
   const bool asia   = IsHourInRange(h, InpAsiaStart, InpAsiaEnd);
   const bool overlap = london && ny;

   if(overlap) name = "Overlap LON+NY";
   else if(london) name = "London";
   else if(ny) name = "NewYork";
   else if(asia) name = "Asian";
   else name = "Off-hours";

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
   s.buy = 0; s.sell = 0;
   s.buy_reasons = ""; s.sell_reasons = "";
   s.rsi = 0; s.atr_pts = 0; s.spread_pts = 0; s.adx = 0;
   s.trend_up = false; s.trend_down = false;
   s.session_ok = false; s.session_name = "";
   s.pullback_buy = 0; s.pullback_sell = 0;

   double fast_t[], slow_t[], fast_s[], slow_s[], rsi[], atr[], adx[];
   if(!CopyBuf(g_ema_fast_trend, 0, 4, fast_t)) return false;
   if(!CopyBuf(g_ema_slow_trend, 0, 4, slow_t)) return false;
   if(!CopyBuf(g_ema_fast_sig,   0, 4, fast_s)) return false;
   if(!CopyBuf(g_ema_slow_sig,   0, 4, slow_s)) return false;
   if(!CopyBuf(g_rsi_handle,     0, 4, rsi))    return false;
   if(!CopyBuf(g_atr_handle,     0, 4, atr))    return false;
   if(!CopyBuf(g_adx_handle,     0, 4, adx))    return false; // buffer 0 = ADX

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0) return false;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   s.rsi = rsi[1]; // закрытый бар — меньше шума
   s.atr_pts = atr[1] / point;
   s.spread_pts = (ask - bid) / point;
   s.adx = adx[1];
   s.trend_up = (fast_t[1] > slow_t[1] && fast_t[1] > fast_t[2]);
   s.trend_down = (fast_t[1] < slow_t[1] && fast_t[1] < fast_t[2]);
   s.session_ok = CheckSession(s.session_name);

   // 1) Старший тренд
   if(fast_t[1] > slow_t[1]) { s.buy++;  s.buy_reasons  += "H1up "; }
   if(fast_t[1] < slow_t[1]) { s.sell++; s.sell_reasons += "H1dn "; }

   // 2) Импульс EMA
   if(s.trend_up)   { s.buy++;  s.buy_reasons  += "impulseUp "; }
   if(s.trend_down) { s.sell++; s.sell_reasons += "impulseDn "; }

   // 3) Согласование сигнального ТФ
   if(fast_s[1] > slow_s[1]) { s.buy++;  s.buy_reasons  += "M15bull "; }
   if(fast_s[1] < slow_s[1]) { s.sell++; s.sell_reasons += "M15bear "; }

   // 4) ADX сила тренда
   if(s.adx >= InpMinADX)
     {
      if(fast_t[1] > slow_t[1]) { s.buy++;  s.buy_reasons  += "ADXok "; }
      if(fast_t[1] < slow_t[1]) { s.sell++; s.sell_reasons += "ADXok "; }
     }

   // 5) RSI в зоне продолжения тренда (не край)
   if(s.rsi > 45.0 && s.rsi < 68.0) { s.buy++;  s.buy_reasons  += "RSIbuy "; }
   if(s.rsi < 55.0 && s.rsi > 32.0) { s.sell++; s.sell_reasons += "RSIsell "; }

   // 6) Бычья/медвежья свеча сигнала
   double o = iOpen(_Symbol, InpSignalTF, 1);
   double c = iClose(_Symbol, InpSignalTF, 1);
   double h = iHigh(_Symbol, InpSignalTF, 1);
   double l = iLow(_Symbol, InpSignalTF, 1);
   double range = h - l;
   if(range > 0.0)
     {
      double body = MathAbs(c - o) / range;
      if(c > o && body >= 0.5) { s.buy++;  s.buy_reasons  += "bullBar "; }
      if(c < o && body >= 0.5) { s.sell++; s.sell_reasons += "bearBar "; }
     }

   // 7) Цена по сторону EMA + качество отката
   if(bid > fast_s[1] && bid > slow_s[1])
     {
      s.buy++;
      s.buy_reasons += "aboveEMA ";
     }
   if(bid < fast_s[1] && bid < slow_s[1])
     {
      s.sell++;
      s.sell_reasons += "belowEMA ";
     }

   // Откат: расстояние до быстрой EMA в долях ATR (ближе = лучше для входа)
   if(atr[1] > 0.0)
     {
      s.pullback_buy  = 1.0 - MathMin(1.0, MathAbs(bid - fast_s[1]) / atr[1]);
      s.pullback_sell = s.pullback_buy;
      if(InpPullbackEntry)
        {
         // Buy: цена около/чуть выше EMA после отката, не далеко в отрыве
         if(bid >= fast_s[1] && (bid - fast_s[1]) <= atr[1] * 0.6)
           { s.buy++; s.buy_reasons += "pullback "; }
         if(bid <= fast_s[1] && (fast_s[1] - bid) <= atr[1] * 0.6)
           { s.sell++; s.sell_reasons += "pullback "; }
        }
     }

   // Бонус лучшей сессии
   if(StringFind(s.session_name, "Overlap") >= 0 || s.session_name == "London" || s.session_name == "NewYork")
     {
      s.buy++;  s.buy_reasons  += "session ";
      s.sell++; s.sell_reasons += "session ";
     }

   return true;
  }

//+------------------------------------------------------------------+
bool FiltersPass(const MarketScore &s, string &reason)
  {
   if(!s.session_ok)
     {
      reason = "вне сессии (" + s.session_name + ")";
      return false;
     }
   if(s.adx < InpMinADX)
     {
      reason = StringFormat("слабый тренд ADX %.1f < %.1f", s.adx, InpMinADX);
      return false;
     }
   if(InpUseSpreadFilter && s.spread_pts > (double)InpMaxSpreadPts)
     {
      reason = StringFormat("спред %.0f", s.spread_pts);
      return false;
     }
   if(s.atr_pts < InpMinATRPoints)
     {
      reason = StringFormat("низкий ATR %.0f", s.atr_pts);
      return false;
     }
   if(InpMaxATRPoints > 0.0 && s.atr_pts > InpMaxATRPoints)
     {
      reason = StringFormat("слишком высокий ATR %.0f", s.atr_pts);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
bool PickEntry(const MarketScore &s, ENUM_ORDER_TYPE &type, string &reason)
  {
   if(!FiltersPass(s, reason))
      return false;

   bool buy_ok  = (s.buy  >= InpMinScore && s.buy  >= s.sell + InpScoreGap && s.trend_up);
   bool sell_ok = (s.sell >= InpMinScore && s.sell >= s.buy  + InpScoreGap && s.trend_down);

   if(InpDirection == DIR_BUY)
     {
      if(!buy_ok) { reason = StringFormat("Buy слаб %d", s.buy); return false; }
      type = ORDER_TYPE_BUY; reason = "BUY " + s.buy_reasons; return true;
     }
   if(InpDirection == DIR_SELL)
     {
      if(!sell_ok) { reason = StringFormat("Sell слаб %d", s.sell); return false; }
      type = ORDER_TYPE_SELL; reason = "SELL " + s.sell_reasons; return true;
     }

   if(buy_ok && (!sell_ok || s.buy > s.sell))
     { type = ORDER_TYPE_BUY; reason = "AUTO BUY " + s.buy_reasons; return true; }
   if(sell_ok && (!buy_ok || s.sell > s.buy))
     { type = ORDER_TYPE_SELL; reason = "AUTO SELL " + s.sell_reasons; return true; }

   reason = StringFormat("нет края Buy=%d Sell=%d ADX=%.1f", s.buy, s.sell, s.adx);
   return false;
  }

//+------------------------------------------------------------------+
int CountOurPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      n++;
     }
   return n;
  }

//+------------------------------------------------------------------+
bool HasOurPosition()
  {
   return CountOurPositions() > 0;
  }

//+------------------------------------------------------------------+
bool SelectOurPosition(ulong &ticket)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
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
double NormalizeLot(double lot)
  {
   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step_lot <= 0.0) step_lot = 0.01;
   int vol_digits = 2;
   if(step_lot >= 1.0) vol_digits = 0;
   else if(step_lot >= 0.1) vol_digits = 1;

   lot = MathFloor(lot / step_lot + 1e-12) * step_lot;
   if(lot < min_lot) lot = min_lot;
   if(lot > max_lot) lot = max_lot;
   return NormalizeDouble(lot, vol_digits);
  }

//+------------------------------------------------------------------+
double CalcLotByRisk(const double sl_points)
  {
   if(sl_points <= 0.0)
      return NormalizeLot(InpLot);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_money = balance * InpRiskPercent / 100.0;

   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(tick_size <= 0.0 || tick_value <= 0.0 || point <= 0.0)
      return NormalizeLot(InpLot);

   double money_per_point = tick_value * (point / tick_size);
   if(money_per_point <= 0.0)
      return NormalizeLot(InpLot);

   double lot = risk_money / (sl_points * money_per_point);
   return NormalizeLot(lot);
  }

//+------------------------------------------------------------------+
void CalcSLTP(const ENUM_ORDER_TYPE type, const MarketScore &s,
              double &sl, double &tp, double &sl_pts)
  {
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   sl_pts = MathMax(s.atr_pts * InpATR_SL_Mult, InpMinATRPoints);

   // SL не ближе 1.2 спреда
   sl_pts = MathMax(sl_pts, s.spread_pts * 1.2 + 10.0);
   double tp_pts = sl_pts * InpRewardRisk;

   if(type == ORDER_TYPE_BUY)
     {
      double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = NormalizeDouble(price - sl_pts * point, digits);
      tp = NormalizeDouble(price + tp_pts * point, digits);
     }
   else
     {
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = NormalizeDouble(price + sl_pts * point, digits);
      tp = NormalizeDouble(price - tp_pts * point, digits);
     }
  }

//+------------------------------------------------------------------+
bool OpenTrade(const ENUM_ORDER_TYPE type, const MarketScore &s, const string reason)
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) return false;

   double sl = 0, tp = 0, sl_pts = 0;
   CalcSLTP(type, s, sl, tp, sl_pts);

   double lot = (InpLotMode == LOT_RISK) ? CalcLotByRisk(sl_pts) : NormalizeLot(InpLot);
   string comment = (type == ORDER_TYPE_BUY) ? "PE Buy" : "PE Sell";

   bool ok = (type == ORDER_TYPE_BUY)
             ? trade.Buy(lot, _Symbol, 0.0, sl, tp, comment)
             : trade.Sell(lot, _Symbol, 0.0, sl, tp, comment);

   if(ok)
     {
      PrintFormat("OPEN %s lot=%.2f SL=%.0fpts | Buy=%d Sell=%d ADX=%.1f | %s",
                  type == ORDER_TYPE_BUY ? "BUY" : "SELL",
                  lot, sl_pts, s.buy, s.sell, s.adx, reason);
      return true;
     }

   PrintFormat("Ошибка OPEN: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   return false;
  }

//+------------------------------------------------------------------+
void ManageOnePosition(const ulong ticket, const MarketScore &s)
  {
   if(!PositionSelectByTicket(ticket))
      return;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return;
   if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
      return;

   long   type = PositionGetInteger(POSITION_TYPE);
   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl   = PositionGetDouble(POSITION_SL);
   double tp   = PositionGetDouble(POSITION_TP);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(point <= 0.0) return;

   double money = PositionProfitMoney();

   // Главное: сразу закрываем, как только плюс достиг порога
   if(InpCloseOnProfit && money >= InpMinProfitMoney)
     {
      if(trade.PositionClose(ticket, InpDeviation))
        {
         g_last_farm_ms = GetTickCount64(); // небольшая пауза перед следующим циклом
         PrintFormat("LOCK PROFIT #%I64u money=%.2f (>= %.2f)", ticket, money, InpMinProfitMoney);
        }
      return;
     }

   double sl_dist = 0.0;
   if(type == POSITION_TYPE_BUY && sl > 0.0)
      sl_dist = (open - sl) / point;
   else if(type == POSITION_TYPE_SELL && sl > 0.0)
      sl_dist = (sl - open) / point;
   if(sl_dist <= 0.0)
      sl_dist = MathMax(s.atr_pts * InpATR_SL_Mult, InpMinATRPoints);

   double profit_pts = (type == POSITION_TYPE_BUY) ? (bid - open) / point : (open - ask) / point;
   double r_now = profit_pts / sl_dist;

   if(InpUseBreakEven && r_now >= InpBE_R)
     {
      double be = 0.0;
      if(type == POSITION_TYPE_BUY)
        {
         be = NormalizeDouble(open + InpBE_OffsetPts * point, digits);
         if(sl < be)
            trade.PositionModify(ticket, be, tp);
        }
      else
        {
         be = NormalizeDouble(open - InpBE_OffsetPts * point, digits);
         if(sl == 0.0 || sl > be)
            trade.PositionModify(ticket, be, tp);
        }
     }

   if(InpUseTrailing && r_now >= InpTrailStart_R && s.atr_pts > 0.0)
     {
      double trail_pts = s.atr_pts * InpTrailATR_Mult;
      if(type == POSITION_TYPE_BUY)
        {
         double new_sl = NormalizeDouble(bid - trail_pts * point, digits);
         if(new_sl > sl && new_sl < bid)
            trade.PositionModify(ticket, new_sl, tp);
        }
      else
        {
         double new_sl = NormalizeDouble(ask + trail_pts * point, digits);
         if((sl == 0.0 || new_sl < sl) && new_sl > ask)
            trade.PositionModify(ticket, new_sl, tp);
        }
     }

   if(InpCloseOnWeakTrend)
     {
      bool weak = (s.adx < InpMinADX * 0.85);
      bool against = (type == POSITION_TYPE_BUY && s.trend_down) ||
                     (type == POSITION_TYPE_SELL && s.trend_up);
      if(weak && against && money < 0.0)
        {
         if(trade.PositionClose(ticket, InpDeviation))
            PrintFormat("EXIT weak-trend #%I64u money=%.2f", ticket, money);
        }
     }
  }

//+------------------------------------------------------------------+
void ManageAllPositions(const MarketScore &s)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      ManageOnePosition(ticket, s);
     }
  }

//+------------------------------------------------------------------+
void UpdatePanel()
  {
   string text = StringFormat(
                    "ProfitScalper v3.20 FARM\n%s | dayPnL: %.2f | open: %d/%d | dayTrades: %d\nlot=%.2f | lock>=$%.2f | loop=%s | paused: %s",
                    _Symbol, g_day_pnl, CountOurPositions(), InpMaxPositions, g_trades_today,
                    InpLot, InpMinProfitMoney, InpFarmLoop ? "ON" : "off",
                    g_trading_paused ? "YES" : "no");
   Comment(text);
  }
//+------------------------------------------------------------------+
