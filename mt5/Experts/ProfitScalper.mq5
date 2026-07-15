//+------------------------------------------------------------------+
//|                                               ProfitScalper.mq5  |
  //|  v3.81 — быстрее вход: сильный M1 + мягкий clear-flow             |
 //+------------------------------------------------------------------+
#property copyright "ProfitScalper"
#property version   "3.81"
#property description "Живой ход M1/M5. Сильный импульс → вход. Полный чоп → ждёт."

#include <Trade/Trade.mqh>
#include "../Include/ChartKnowledge.mqh"

enum ENUM_TRADE_DIRECTION
  {
   DIR_BUY  = 0,
   DIR_SELL = 1,
   DIR_AUTO = 2
  };

input group "=== Торговля ==="
input ENUM_TRADE_DIRECTION InpDirection = DIR_AUTO;
input double               InpLot       = 0.10;      // Лот (на графике золота = лот золота)
input int                  InpMagic     = 26071470;
input int                  InpDeviation = 30;
input int                  InpMaxPositions = 3;      // Позиций (меньше — меньше просадка)
input int                  InpBasketOpen = 3;        // Открывать за заход
input int                  InpMaxTradesDay = 200;
input bool                 InpFarmLoop = true;
input int                  InpFarmCooldownMs = 1500; // Не спамить корзинами
input bool                 InpRefillBasket = true;

input group "=== Символ ==="
input bool                 InpTradeOnlyChart = true; // Только символ ЭТОГО графика
input string               InpAlsoSymbols = "";      // Пусто = никого больше не трогать

input group "=== Предикт прибыли ==="
input bool                 InpUseKnowledge = true;     // Свечи → вверх или вниз
input bool                 InpSmartBigProfit = true;   // Сильный предикт → держим на большой плюс
input double               InpMinProfitMoney = 0.50;   // Мин. плюс ($) если предикт слабый
input double               InpBigProfitMoney = 5.00;   // Цель ($) при СИЛЬНОМ предикте
input double               InpStrongScoreGap = 6.0;    // Насколько buy/sell должны разойтись
input double               InpStrongRR = 3.0;          // TP в R при сильном предикте
input double               InpWeakRR = 1.5;            // TP в R при слабом предикте
input bool                 InpCloseOnProfit  = true;
input bool                 InpCloseEachAlone = true;
input int                  InpLockTimerMs    = 100;
input bool                 InpUseBreakEven = true;
input double               InpBE_R = 0.8;
input double               InpBE_OffsetPts = 3.0;
input bool                 InpUseTrailing = true;
input double               InpTrailStart_R = 1.0;
input double               InpTrailATR_Mult = 0.9;

input group "=== Анализ ==="
input ENUM_TIMEFRAMES      InpTrendTF   = PERIOD_H1;
input ENUM_TIMEFRAMES      InpSignalTF  = PERIOD_M15;
input int                  InpFastEMA   = 20;
input int                  InpSlowEMA   = 50;
input int                  InpATRPeriod = 14;
input double               InpATR_SL_Mult = 1.8;
input bool                 InpUseSpreadFilter = true;
input int                  InpMaxSpreadPts = 300;      // золото

input group "=== База знаний ==="
input bool                 InpStickyLastDir = false;
input int                  InpKnowledgeGap = 0;
input bool                 InpRequireClearFlow = true; // Только когда M1+голоса согласны
input bool                 InpCloseAgainstFlow = true;  // Закрыть корзину если рынок развернулся
input double               InpBasketCutLoss = 8.0;      // Резать всю корзину если суммарный минус >= $

input group "=== Защита ==="
input bool                 InpMaxLossDay = true;
input double               InpMaxLossMoney = 80.0;
input bool                 InpMaxLossPct = true;
input double               InpMaxLossPercent = 3.0;

#define MAX_SYMS 8

CTrade trade;

string g_syms[MAX_SYMS];
int    g_sym_count = 0;
int    g_ema_fast[MAX_SYMS];
int    g_ema_slow[MAX_SYMS];
int    g_atr[MAX_SYMS];
ulong  g_last_farm_ms[MAX_SYMS];
ulong  g_last_skip_ms[MAX_SYMS];
ulong  g_pause_until_ms[MAX_SYMS];
ENUM_ORDER_TYPE g_last_dir[MAX_SYMS];
bool   g_have_dir[MAX_SYMS];
double g_pred_gap[MAX_SYMS];
bool   g_pred_strong[MAX_SYMS];
double g_lock_target[MAX_SYMS];
string g_pred_side[MAX_SYMS];
double g_score_buy[MAX_SYMS];
double g_score_sell[MAX_SYMS];
string g_score_why[MAX_SYMS];
string g_wait_why[MAX_SYMS];

datetime g_day_start = 0;
double   g_day_pnl = 0.0;
double   g_day_start_balance = 0.0;
bool     g_trading_paused = false;
int      g_trades_today = 0;

struct MarketScore
  {
   double atr_pts;
   double spread_pts;
   bool   trend_up;
   bool   trend_down;
  };

//+------------------------------------------------------------------+
string TrimStr(string s)
  {
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
  }

//+------------------------------------------------------------------+
bool IsGoldSymbol(const string sym)
  {
   string u = sym;
   StringToUpper(u);
   return (StringFind(u, "XAU") >= 0 || StringFind(u, "GOLD") >= 0);
  }

//+------------------------------------------------------------------+
double LotForSymbol(const string sym)
  {
   return InpLot;
  }

//+------------------------------------------------------------------+
double MinProfitForSymbol(const string sym)
  {
   for(int i = 0; i < g_sym_count; i++)
     {
      if(g_syms[i] == sym)
         return MathMax(g_lock_target[i], InpMinProfitMoney);
     }
   return InpMinProfitMoney;
  }

//+------------------------------------------------------------------+
string ResolveGoldName()
  {
   string cands[] = {"XAUUSD", "XAUUSDm", "XAUUSD.", "GOLD", "GOLDm", "XAUUSD.a"};
   for(int i = 0; i < ArraySize(cands); i++)
     {
      if(SymbolSelect(cands[i], true))
         return cands[i];
     }
   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
     {
      string name = SymbolName(i, false);
      string u = name;
      StringToUpper(u);
      if(StringFind(u, "XAUUSD") >= 0 || u == "GOLD")
        {
         SymbolSelect(name, true);
         return name;
        }
     }
   return "";
  }

//+------------------------------------------------------------------+
void AddSymbolUnique(const string sym)
  {
   if(sym == "" || g_sym_count >= MAX_SYMS)
      return;
   for(int i = 0; i < g_sym_count; i++)
      if(g_syms[i] == sym)
         return;
   if(!SymbolSelect(sym, true))
     {
      PrintFormat("Символ недоступен: %s", sym);
      return;
     }
   g_syms[g_sym_count++] = sym;
  }

//+------------------------------------------------------------------+
void BuildSymbolList()
  {
   g_sym_count = 0;
   // По умолчанию — ТОЛЬКО символ графика, куда накинули EA
   if(InpTradeOnlyChart || InpAlsoSymbols == "")
     {
      AddSymbolUnique(_Symbol);
      return;
     }

   AddSymbolUnique(_Symbol);
   string raw = InpAlsoSymbols;
   string parts[];
   int n = StringSplit(raw, ',', parts);
   for(int i = 0; i < n; i++)
     {
      string s = TrimStr(parts[i]);
      if(s == "")
         continue;
      string u = s;
      StringToUpper(u);
      if(u == "XAUUSD" || u == "GOLD" || u == "XAU")
        {
         string g = ResolveGoldName();
         if(g != "")
            AddSymbolUnique(g);
         continue;
        }
      AddSymbolUnique(s);
     }

   if(g_sym_count == 0)
      AddSymbolUnique(_Symbol);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetAsyncMode(false);

   BuildSymbolList();
   if(g_sym_count < 1)
     {
      Print("Нет символов для торговли");
      return INIT_FAILED;
     }

   for(int i = 0; i < g_sym_count; i++)
     {
      g_ema_fast[i] = iMA(g_syms[i], InpTrendTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
      g_ema_slow[i] = iMA(g_syms[i], InpTrendTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
      g_atr[i]      = iATR(g_syms[i], InpSignalTF, InpATRPeriod);
      g_last_farm_ms[i] = 0;
      g_last_skip_ms[i] = 0;
      g_pause_until_ms[i] = 0;
      g_last_dir[i] = ORDER_TYPE_BUY;
      g_have_dir[i] = false;
      g_pred_gap[i] = 0;
      g_pred_strong[i] = false;
      g_lock_target[i] = InpMinProfitMoney;
      g_pred_side[i] = "?";
      g_score_buy[i] = 0;
      g_score_sell[i] = 0;
      g_score_why[i] = "-";
      g_wait_why[i] = "";
      if(g_ema_fast[i] == INVALID_HANDLE || g_ema_slow[i] == INVALID_HANDLE || g_atr[i] == INVALID_HANDLE)
        {
         PrintFormat("Индикаторы не созданы для %s", g_syms[i]);
         return INIT_FAILED;
        }
      PrintFormat("Символ: %s %s (только график)", g_syms[i], IsGoldSymbol(g_syms[i]) ? "[GOLD]" : "");
     }

   g_day_start = DayStart();
   g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_day_pnl = 0.0;
   g_trades_today = 0;

   int ms = MathMax(InpLockTimerMs, 50);
   if(!EventSetMillisecondTimer(ms))
      Print("Timer fail — LOCK только на тиках графика");

   PrintFormat("ProfitScalper v3.81 FLOW | chart=%s | lot=%.2f | min$=%.2f | clearFlow=%s | cut=$%.1f",
               _Symbol, InpLot, InpMinProfitMoney,
               InpRequireClearFlow ? "ON" : "off", InpBasketCutLoss);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   for(int i = 0; i < g_sym_count; i++)
     {
      IndicatorRelease(g_ema_fast[i]);
      IndicatorRelease(g_ema_slow[i]);
      IndicatorRelease(g_atr[i]);
     }
   Comment("");
   Print("ProfitScalper остановлен");
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   if(g_trading_paused) return;
   ManageAllPositions();
   for(int i = 0; i < g_sym_count; i++)
      ProtectAgainstFlow(i);
   if(InpFarmLoop && g_trades_today < InpMaxTradesDay)
     {
      for(int i = 0; i < g_sym_count; i++)
         FarmSymbol(i);
     }
   UpdatePanel();
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
      PrintFormat("Дневной лимит: %.2f — стоп", g_day_pnl);
      return;
     }

   // Сначала LOCK на каждом тике (еще быстрее реакции)
   ManageAllPositions();
   for(int i = 0; i < g_sym_count; i++)
      ProtectAgainstFlow(i);

   if(g_trades_today >= InpMaxTradesDay)
      return;

   if(!InpFarmLoop)
      return;

   for(int i = 0; i < g_sym_count; i++)
      FarmSymbol(i);
  }

//+------------------------------------------------------------------+
void FarmSymbol(const int idx)
  {
   const string sym = g_syms[idx];
   int open_now = CountOurPositions(sym);

   MarketScore score;
   if(!AnalyzeSymbol(idx, score))
      return;

   ENUM_ORDER_TYPE type;
   string reason;
   bool can_trade = ResolveDir(idx, score, type, reason);

   // Не доливаем против текущего потока (и против уже открытой стороны)
   if(open_now > 0 && can_trade)
     {
      int our = -1;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
         if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         if(PositionGetString(POSITION_SYMBOL) != sym) continue;
         our = (int)PositionGetInteger(POSITION_TYPE);
         break;
        }
      if(our >= 0)
        {
         bool mismatch = ((our == POSITION_TYPE_BUY && type == ORDER_TYPE_SELL) ||
                          (our == POSITION_TYPE_SELL && type == ORDER_TYPE_BUY));
         if(mismatch)
            return; // ждём ProtectAgainstFlow, не открываем хедж-бред
        }
     }

   if(!InpRefillBasket)
     {
      if(open_now > 0)
         return;
     }
   else if(open_now >= InpMaxPositions)
      return;

   if(!can_trade)
      return;

   if(g_pause_until_ms[idx] > 0 && GetTickCount64() < g_pause_until_ms[idx])
      return;

   if(g_last_farm_ms[idx] > 0 &&
      (GetTickCount64() - g_last_farm_ms[idx]) < (ulong)MathMax(InpFarmCooldownMs, 50))
      return;

   if(InpUseSpreadFilter)
     {
      int max_spread = InpMaxSpreadPts;
      if(IsGoldSymbol(sym))
         max_spread = MathMax(max_spread, 300);
      if(score.spread_pts > (double)max_spread)
         return;
     }

   // Меньше «ковыряния»: 3 вместо агрессивной пятёрки при слабом flow
   int basket = InpBasketOpen;
   if(!g_pred_strong[idx])
      basket = MathMin(basket, 3);

   int need = MathMin(basket, InpMaxPositions - open_now);
   if(need <= 0)
      return;

   int opened = OpenBasket(sym, type, score, reason, need);
   if(opened > 0)
     {
      g_last_farm_ms[idx] = GetTickCount64();
      g_last_dir[idx] = type;
      g_have_dir[idx] = true;
      g_wait_why[idx] = "";
      PrintFormat("FARM %s: +%d %s (open=%d/%d) lot=%.2f", sym, opened,
                  type == ORDER_TYPE_BUY ? "BUY" : "SELL",
                  open_now + opened, InpMaxPositions, LotForSymbol(sym));
     }
  }

//+------------------------------------------------------------------+
bool AnalyzeSymbol(const int idx, MarketScore &s)
  {
   s.atr_pts = 0; s.spread_pts = 0; s.trend_up = false; s.trend_down = false;
   string sym = g_syms[idx];

   double fast[], slow[], atr[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_ema_fast[idx], 0, 0, 3, fast) < 3) return false;
   if(CopyBuffer(g_ema_slow[idx], 0, 0, 3, slow) < 3) return false;
   if(CopyBuffer(g_atr[idx], 0, 0, 3, atr) < 3) return false;

   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(point <= 0.0) return false;
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   s.spread_pts = (ask - bid) / point;
   s.atr_pts = atr[1] / point;
   // Мягкий тренд: положение EMA, без требования «растущей» fast
   s.trend_up = (fast[1] > slow[1]);
   s.trend_down = (fast[1] < slow[1]);
   return true;
  }

//+------------------------------------------------------------------+
void UpdatePrediction(const int idx, const MarketScore &s)
  {
   KnowledgeScore ks = EvaluateKnowledge(g_syms[idx], InpSignalTF, s.trend_up, s.trend_down);
   double gap = MathAbs(ks.buy - ks.sell);
   g_pred_gap[idx] = gap;
   g_pred_strong[idx] = (InpSmartBigProfit && gap >= InpStrongScoreGap);

   if(ks.buy > ks.sell)
      g_pred_side[idx] = "UP/BUY";
   else if(ks.sell > ks.buy)
      g_pred_side[idx] = "DOWN/SELL";
   else
      g_pred_side[idx] = "TIE";

   if(g_pred_strong[idx])
     {
      g_lock_target[idx] = InpBigProfitMoney;
      PrintFormat("PRED STRONG %s %s gap=%.1f → цель $%.2f (держать ход)",
                  g_syms[idx], g_pred_side[idx], gap, g_lock_target[idx]);
     }
   else
     {
      g_lock_target[idx] = InpMinProfitMoney;
      PrintFormat("PRED soft %s %s gap=%.1f → мин $%.2f",
                  g_syms[idx], g_pred_side[idx], gap, g_lock_target[idx]);
     }
  }

//+------------------------------------------------------------------+
// true = можно открывать; false = ждём (анализ всё равно в панели)
bool ResolveDir(const int idx, const MarketScore &s, ENUM_ORDER_TYPE &type, string &reason)
  {
   g_wait_why[idx] = "";

   if(InpDirection == DIR_BUY)
     { type = ORDER_TYPE_BUY; reason = "fixed BUY"; g_pred_side[idx]="UP/BUY"; return true; }
   if(InpDirection == DIR_SELL)
     { type = ORDER_TYPE_SELL; reason = "fixed SELL"; g_pred_side[idx]="DOWN/SELL"; return true; }

   MarketFlow flow = ReadMarketFlow(g_syms[idx]);
   KnowledgeScore ks = EvaluateKnowledge(g_syms[idx], InpSignalTF, s.trend_up, s.trend_down);
   g_score_buy[idx] = ks.buy;
   g_score_sell[idx] = ks.sell;
   g_score_why[idx] = flow.reason;
   g_pred_gap[idx] = MathAbs(ks.buy - ks.sell);
   type = flow.dir;
   g_pred_side[idx] = (type == ORDER_TYPE_BUY ? "UP/BUY" : "DOWN/SELL");

   if(InpRequireClearFlow && !flow.clear)
     {
      g_pred_strong[idx] = false;
      g_lock_target[idx] = InpMinProfitMoney;
      g_wait_why[idx] = StringFormat(
         "ЖДЁМ ясный ход рынка: голоса BUY %d / SELL %d | M1=%.0fpts. Не торгуем шум.",
         flow.buy_v, flow.sell_v, flow.m1_pts);
      if(g_last_skip_ms[idx] == 0 ||
         (GetTickCount64() - g_last_skip_ms[idx]) >= 8000)
        {
         g_last_skip_ms[idx] = GetTickCount64();
         PrintFormat("WAIT %s | %s | %s", g_syms[idx], g_wait_why[idx], flow.reason);
        }
      reason = "WAIT chop " + flow.reason;
      return false;
     }

   g_pred_strong[idx] = (InpSmartBigProfit && flow.clear &&
                         MathAbs(flow.buy_v - flow.sell_v) >= 3 &&
                         MathAbs(flow.m1_pts) >= 80.0);
   g_lock_target[idx] = g_pred_strong[idx] ? InpBigProfitMoney : InpMinProfitMoney;
   g_wait_why[idx] = "";
   reason = StringFormat("FLOW %s B%d/S%d | BUY=%.1f SELL=%.1f lock$=%.2f%s | %s",
                         type == ORDER_TYPE_BUY ? "BUY" : "SELL",
                         flow.buy_v, flow.sell_v,
                         g_score_buy[idx], g_score_sell[idx],
                         g_lock_target[idx],
                         g_pred_strong[idx] ? " BIG" : "",
                         flow.reason);
   return true;
  }

//+------------------------------------------------------------------+
double BasketMoney(const string sym)
  {
   double sum = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      sum += PositionMoneyNow(ticket);
     }
   return sum;
  }

//+------------------------------------------------------------------+
int CloseOurSymbol(const string sym, const string why)
  {
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(trade.PositionClose(ticket, InpDeviation))
         closed++;
     }
   if(closed > 0)
      PrintFormat("CUT %s x%d | %s", sym, closed, why);
   return closed;
  }

//+------------------------------------------------------------------+
// Если рынок развернулся против открытых — режем. Не доливаем против хода.
void ProtectAgainstFlow(const int idx)
  {
   const string sym = g_syms[idx];
   int open_n = CountOurPositions(sym);
   if(open_n <= 0)
      return;

   double basket = BasketMoney(sym);
   if(basket <= -MathAbs(InpBasketCutLoss))
     {
      CloseOurSymbol(sym, StringFormat("basket loss $%.2f <= -%.2f", basket, InpBasketCutLoss));
      g_pause_until_ms[idx] = GetTickCount64() + 12000;
      return;
     }

   if(!InpCloseAgainstFlow)
      return;

   // Какая сторона у нас открыта?
   int our = -1;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      our = (int)PositionGetInteger(POSITION_TYPE);
      break;
     }
   if(our < 0)
      return;

   MarketFlow flow = ReadMarketFlow(sym);
   if(!flow.clear)
      return; // в чопе не режем агрессивно — ждём cut по $

   bool against = ((our == POSITION_TYPE_BUY && flow.dir == ORDER_TYPE_SELL) ||
                   (our == POSITION_TYPE_SELL && flow.dir == ORDER_TYPE_BUY));
   if(!against)
      return;

   // Режем только если уже в минусе или сильный импульс против
   if(basket < -1.0 || MathAbs(flow.m1_pts) >= 120.0)
     {
      CloseOurSymbol(sym, StringFormat(
         "против потока FLOW %s B%d/S%d M1=%.0f basket=$%.2f",
         flow.dir == ORDER_TYPE_BUY ? "BUY" : "SELL",
         flow.buy_v, flow.sell_v, flow.m1_pts, basket));
      g_pause_until_ms[idx] = GetTickCount64() + 15000;
     }
  }

//+------------------------------------------------------------------+
bool OpenTrade(const string sym, const ENUM_ORDER_TYPE type, const MarketScore &s, const string reason)
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) return false;

   trade.SetTypeFillingBySymbol(sym);

   int idx = 0;
   for(int i = 0; i < g_sym_count; i++)
      if(g_syms[i] == sym) { idx = i; break; }

   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double sl_pts = MathMax(s.atr_pts * InpATR_SL_Mult, 30.0);
   sl_pts = MathMax(sl_pts, s.spread_pts * 1.5 + 20.0);

   // Сильный предикт → шире TP (большая прибыль)
   double rr = g_pred_strong[idx] ? InpStrongRR : InpWeakRR;
   double tp_pts = sl_pts * rr;

   double sl = 0, tp = 0;
   if(type == ORDER_TYPE_BUY)
     {
      double price = SymbolInfoDouble(sym, SYMBOL_ASK);
      sl = NormalizeDouble(price - sl_pts * point, digits);
      tp = NormalizeDouble(price + tp_pts * point, digits);
     }
   else
     {
      double price = SymbolInfoDouble(sym, SYMBOL_BID);
      sl = NormalizeDouble(price + sl_pts * point, digits);
      tp = NormalizeDouble(price - tp_pts * point, digits);
     }

   double lot = NormalizeLot(sym, LotForSymbol(sym));
   // Комментарий виден на телефоне во вкладке Торговля
   string comment = StringFormat("%s %.0f>%.0f",
                                 type == ORDER_TYPE_BUY ? "BUY" : "SELL",
                                 type == ORDER_TYPE_BUY ? g_score_buy[idx] : g_score_sell[idx],
                                 type == ORDER_TYPE_BUY ? g_score_sell[idx] : g_score_buy[idx]);
   if(StringLen(comment) > 31)
      comment = StringSubstr(comment, 0, 31);

   bool ok = (type == ORDER_TYPE_BUY)
             ? trade.Buy(lot, sym, 0.0, sl, tp, comment)
             : trade.Sell(lot, sym, 0.0, sl, tp, comment);

   if(ok)
      PrintFormat("OPEN %s %s lot=%.2f RR=%.1f lock$=%.2f | %s",
                  sym, type == ORDER_TYPE_BUY ? "BUY" : "SELL", lot, rr, g_lock_target[idx], reason);
   else
      PrintFormat("OPEN fail %s: %d %s", sym, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   return ok;
  }

//+------------------------------------------------------------------+
int OpenBasket(const string sym, const ENUM_ORDER_TYPE type, const MarketScore &s,
               const string reason, const int basket)
  {
   int opened = 0;
   for(int i = 0; i < basket; i++)
     {
      if(g_trades_today >= InpMaxTradesDay) break;
      if(CountOurPositions(sym) >= InpMaxPositions) break;
      if(OpenTrade(sym, type, s, reason + StringFormat(" #%d", i + 1)))
        {
         g_trades_today++;
         opened++;
        }
      else break;
     }
   return opened;
  }

//+------------------------------------------------------------------+
double NormalizeLot(const string sym, double lot)
  {
   double min_lot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step_lot = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
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
int CountOurPositions(const string sym = "")
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(sym != "" && PositionGetString(POSITION_SYMBOL) != sym) continue;
      n++;
     }
   return n;
  }

//+------------------------------------------------------------------+
double PositionMoneyNow(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return -1e9;
   // Floating P/L брокера
   double money = PositionGetDouble(POSITION_PROFIT)
                  + PositionGetDouble(POSITION_SWAP);

   // Дополнительно считаем по тику — иногда PROFIT обновляется медленнее UI
   string sym = PositionGetString(POSITION_SYMBOL);
   long type = PositionGetInteger(POSITION_TYPE);
   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double vol  = PositionGetDouble(POSITION_VOLUME);
   double tick_val = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tick_sz  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   if(tick_sz > 0.0 && tick_val > 0.0)
     {
      double price = (type == POSITION_TYPE_BUY) ? bid : ask;
      double pts = (type == POSITION_TYPE_BUY) ? (price - open) : (open - price);
      double calc = (pts / tick_sz) * tick_val * vol;
      // берём более «свежую» оценку вверх для lock (быстрее реакция на плюс)
      if(calc > money)
         money = calc;
     }
   return money;
  }

//+------------------------------------------------------------------+
void ManageAllPositions()
  {
   // Копия тикетов — после Close индексы плывут
   ulong tickets[];
   ArrayResize(tickets, 0);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      int n = ArraySize(tickets);
      ArrayResize(tickets, n + 1);
      tickets[n] = ticket;
     }

   for(int i = 0; i < ArraySize(tickets); i++)
      ManageOne(tickets[i]);
  }

//+------------------------------------------------------------------+
void ManageOne(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return;
   string sym = PositionGetString(POSITION_SYMBOL);
   double money = PositionMoneyNow(ticket);
   double lock_at = MinProfitForSymbol(sym);

   // Каждая позиция сама по себе — без ожидания остальных
   if(InpCloseOnProfit && InpCloseEachAlone && money >= lock_at)
     {
      if(trade.PositionClose(ticket, InpDeviation))
        {
         // Короткий cooldown только для долития, не блокирует другие LOCK
         for(int i = 0; i < g_sym_count; i++)
            if(g_syms[i] == sym)
               g_last_farm_ms[i] = GetTickCount64();
         PrintFormat("LOCK NOW %s #%I64u +%.2f (>=%.2f) alone", sym, ticket, money, lock_at);
        }
      else
         PrintFormat("LOCK FAIL %s #%I64u +%.2f ret=%d %s",
                     sym, ticket, money, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return;
     }

   // BE / trailing — только если ещё не в зоне мгновенного lock
   long type = PositionGetInteger(POSITION_TYPE);
   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   if(point <= 0) return;

   double sl_dist = 0;
   if(type == POSITION_TYPE_BUY && sl > 0) sl_dist = (open - sl) / point;
   if(type == POSITION_TYPE_SELL && sl > 0) sl_dist = (sl - open) / point;
   if(sl_dist <= 0) sl_dist = 100;
   double profit_pts = (type == POSITION_TYPE_BUY) ? (bid - open) / point : (open - ask) / point;
   double r_now = profit_pts / sl_dist;

   if(InpUseBreakEven && r_now >= InpBE_R)
     {
      if(type == POSITION_TYPE_BUY)
        {
         double be = NormalizeDouble(open + InpBE_OffsetPts * point, digits);
         if(sl < be) trade.PositionModify(ticket, be, tp);
        }
      else
        {
         double be = NormalizeDouble(open - InpBE_OffsetPts * point, digits);
         if(sl == 0 || sl > be) trade.PositionModify(ticket, be, tp);
        }
     }

   if(InpUseTrailing && r_now >= InpTrailStart_R)
     {
      double trail_pts = sl_dist * InpTrailATR_Mult * 0.5;
      if(type == POSITION_TYPE_BUY)
        {
         double nsl = NormalizeDouble(bid - trail_pts * point, digits);
         if(nsl > sl && nsl < bid) trade.PositionModify(ticket, nsl, tp);
        }
      else
        {
         double nsl = NormalizeDouble(ask + trail_pts * point, digits);
         if((sl == 0 || nsl < sl) && nsl > ask) trade.PositionModify(ticket, nsl, tp);
        }
     }
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if((long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic) return;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) return;
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
   if(start == g_day_start) return;
   g_day_start = start;
   g_day_pnl = 0;
   g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_trading_paused = false;
   g_trades_today = 0;
   Print("Новый день — лимиты сброшены");
  }

//+------------------------------------------------------------------+
bool DayRiskHit()
  {
   if(InpMaxLossDay && g_day_pnl <= -MathAbs(InpMaxLossMoney)) return true;
   if(InpMaxLossPct && g_day_start_balance > 0)
     {
      double lim = g_day_start_balance * InpMaxLossPercent / 100.0;
      if(g_day_pnl <= -lim) return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
void UpdatePanel()
  {
   string list = "";
   for(int i = 0; i < g_sym_count; i++)
     {
      if(i > 0) list += "\n----\n";
      string wait = (g_wait_why[i] != "" ? ("\n" + g_wait_why[i]) : "");
      list += StringFormat(
                 "%s  pos=%d\nАНАЛИЗ СВЕЧЕЙ (не рандом):\nBUY %.1f  vs  SELL %.1f  →  %s%s\nцель lock $%.2f | gap %.1f\n%s%s",
                 g_syms[i], CountOurPositions(g_syms[i]),
                 g_score_buy[i], g_score_sell[i], g_pred_side[i],
                 g_pred_strong[i] ? " [BIG]" : "",
                 g_lock_target[i], g_pred_gap[i],
                 g_score_why[i], wait);
     }
   Comment(StringFormat(
              "ProfitScalper v3.81 — куда идёт рынок СЕЙЧАС\n%s\n————\ndayPnL %.2f | trades %d | lot %.2f | pause %s\nСильный M1 → вход. Только полный чоп → ждём.",
              list, g_day_pnl, g_trades_today, InpLot,
              g_trading_paused ? "YES" : "no"));
  }
//+------------------------------------------------------------------+
