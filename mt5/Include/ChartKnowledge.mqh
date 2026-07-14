//+------------------------------------------------------------------+
//|                                              ChartKnowledge.mqh  |
 //|  База знаний v2: непрерывный score → всегда BUY или SELL         |
 //+------------------------------------------------------------------+
#ifndef CHART_KNOWLEDGE_MQH
#define CHART_KNOWLEDGE_MQH

struct CandleFacts
  {
   double o, h, l, c;
   double body;
   double range;
   double upper;
   double lower;
   double body_ratio;
   double close_loc;
   bool   bull;
   bool   bear;
   bool   doji;
  };

struct KnowledgeScore
  {
   double buy;     // непрерывные баллы
   double sell;
   string reason;
  };

//+------------------------------------------------------------------+
bool FillCandle(const string sym, const ENUM_TIMEFRAMES tf, const int shift, CandleFacts &f)
  {
   double o[], h[], l[], c[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);
   ArraySetAsSeries(c, true);
   if(CopyOpen(sym, tf, shift, 1, o) < 1) return false;
   if(CopyHigh(sym, tf, shift, 1, h) < 1) return false;
   if(CopyLow(sym, tf, shift, 1, l) < 1) return false;
   if(CopyClose(sym, tf, shift, 1, c) < 1) return false;

   f.o = o[0]; f.h = h[0]; f.l = l[0]; f.c = c[0];
   f.body  = MathAbs(f.c - f.o);
   f.range = f.h - f.l;
   if(f.range <= 0.0)
      f.range = MathMax(SymbolInfoDouble(sym, SYMBOL_POINT), 1e-10);
   f.upper = f.h - MathMax(f.o, f.c);
   f.lower = MathMin(f.o, f.c) - f.l;
   f.body_ratio = f.body / f.range;
   f.close_loc  = (f.c - f.l) / f.range;
   f.bull = (f.c > f.o);
   f.bear = (f.c < f.o);
   f.doji = (f.body_ratio < 0.12);
   return true;
  }

//+------------------------------------------------------------------+
bool IsHammer(const CandleFacts &f)
  {
   return (f.lower >= 1.8 * MathMax(f.body, f.range * 0.05) &&
           f.upper <= f.body * 1.2 && f.close_loc >= 0.55);
  }

//+------------------------------------------------------------------+
bool IsShootingStar(const CandleFacts &f)
  {
   return (f.upper >= 1.8 * MathMax(f.body, f.range * 0.05) &&
           f.lower <= f.body * 1.2 && f.close_loc <= 0.45);
  }

//+------------------------------------------------------------------+
bool IsBullEngulf(const CandleFacts &prev, const CandleFacts &cur)
  {
   return (prev.bear && cur.bull && cur.c >= prev.o && cur.o <= prev.c && cur.body >= prev.body * 0.9);
  }

//+------------------------------------------------------------------+
bool IsBearEngulf(const CandleFacts &prev, const CandleFacts &cur)
  {
   return (prev.bull && cur.bear && cur.c <= prev.o && cur.o >= prev.c && cur.body >= prev.body * 0.9);
  }

//+------------------------------------------------------------------+
// Сумма тел: >0 бычий импульс, <0 медвежий (в пунктах цены)
double BodyImpulse(const string sym, const ENUM_TIMEFRAMES tf, const int bars)
  {
   double o[], c[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(c, true);
   int n = MathMax(bars, 2);
   if(CopyOpen(sym, tf, 1, n, o) < n) return 0.0;
   if(CopyClose(sym, tf, 1, n, c) < n) return 0.0;
   double sum = 0.0;
   for(int i = 0; i < n; i++)
      sum += (c[i] - o[i]);
   return sum;
  }

//+------------------------------------------------------------------+
// Наклон закрытий: close[1] vs close[1+look]
double CloseSlope(const string sym, const ENUM_TIMEFRAMES tf, const int look)
  {
   double c[];
   ArraySetAsSeries(c, true);
   int n = MathMax(look + 1, 2);
   if(CopyClose(sym, tf, 1, n, c) < n) return 0.0;
   return (c[0] - c[look]);
  }

//+------------------------------------------------------------------+
// Доля бычьих закрытых свечей среди последних n
double BullRatio(const string sym, const ENUM_TIMEFRAMES tf, const int bars)
  {
   double o[], c[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(c, true);
   int n = MathMax(bars, 2);
   if(CopyOpen(sym, tf, 1, n, o) < n) return 0.5;
   if(CopyClose(sym, tf, 1, n, c) < n) return 0.5;
   int bull = 0;
   for(int i = 0; i < n; i++)
      if(c[i] > o[i]) bull++;
   return (double)bull / (double)n;
  }

//+------------------------------------------------------------------+
bool StructureBull(const string sym, const ENUM_TIMEFRAMES tf)
  {
   double h[], l[];
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);
   if(CopyHigh(sym, tf, 1, 8, h) < 8) return false;
   if(CopyLow(sym, tf, 1, 8, l) < 8) return false;
   double hh_recent = MathMax(h[0], MathMax(h[1], h[2]));
   double hh_older  = MathMax(h[4], MathMax(h[5], h[6]));
   double ll_recent = MathMin(l[0], MathMin(l[1], l[2]));
   double ll_older  = MathMin(l[4], MathMin(l[5], l[6]));
   return (hh_recent >= hh_older && ll_recent > ll_older);
  }

//+------------------------------------------------------------------+
bool StructureBear(const string sym, const ENUM_TIMEFRAMES tf)
  {
   double h[], l[];
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);
   if(CopyHigh(sym, tf, 1, 8, h) < 8) return false;
   if(CopyLow(sym, tf, 1, 8, l) < 8) return false;
   double hh_recent = MathMax(h[0], MathMax(h[1], h[2]));
   double hh_older  = MathMax(h[4], MathMax(h[5], h[6]));
   double ll_recent = MathMin(l[0], MathMin(l[1], l[2]));
   double ll_older  = MathMin(l[4], MathMin(l[5], l[6]));
   return (hh_recent <= hh_older && ll_recent < ll_older);
  }

//+------------------------------------------------------------------+
bool ThreeSoldiers(const string sym, const ENUM_TIMEFRAMES tf)
  {
   CandleFacts a, b, c;
   if(!FillCandle(sym, tf, 3, a) || !FillCandle(sym, tf, 2, b) || !FillCandle(sym, tf, 1, c))
      return false;
   return (a.bull && b.bull && c.bull && b.c > a.c && c.c > b.c);
  }

//+------------------------------------------------------------------+
bool ThreeCrows(const string sym, const ENUM_TIMEFRAMES tf)
  {
   CandleFacts a, b, c;
   if(!FillCandle(sym, tf, 3, a) || !FillCandle(sym, tf, 2, b) || !FillCandle(sym, tf, 1, c))
      return false;
   return (a.bear && b.bear && c.bear && b.c < a.c && c.c < b.c);
  }

//+------------------------------------------------------------------+
bool MorningStarLike(const string sym, const ENUM_TIMEFRAMES tf)
  {
   CandleFacts a, b, c;
   if(!FillCandle(sym, tf, 3, a) || !FillCandle(sym, tf, 2, b) || !FillCandle(sym, tf, 1, c))
      return false;
   return (a.bear && b.body_ratio < 0.35 && c.bull && c.c > (a.o + a.c) * 0.5);
  }

//+------------------------------------------------------------------+
bool EveningStarLike(const string sym, const ENUM_TIMEFRAMES tf)
  {
   CandleFacts a, b, c;
   if(!FillCandle(sym, tf, 3, a) || !FillCandle(sym, tf, 2, b) || !FillCandle(sym, tf, 1, c))
      return false;
   return (a.bull && b.body_ratio < 0.35 && c.bear && c.c < (a.o + a.c) * 0.5);
  }

//+------------------------------------------------------------------+
void AddTFVotes(const string sym, const ENUM_TIMEFRAMES tf, const string tag,
                KnowledgeScore &s)
  {
   CandleFacts cur, prev;
   if(!FillCandle(sym, tf, 1, cur) || !FillCandle(sym, tf, 2, prev))
      return;

   // цвет + сила тела
   double body_w = 1.0 + cur.body_ratio * 2.0;
   if(cur.bull) { s.buy  += body_w; s.reason += tag + "bull "; }
   if(cur.bear) { s.sell += body_w; s.reason += tag + "bear "; }

   // закрытие в верхней/нижней четверти диапазона
   if(cur.close_loc >= 0.75) { s.buy  += 1.5; s.reason += tag + "closeHi "; }
   if(cur.close_loc <= 0.25) { s.sell += 1.5; s.reason += tag + "closeLo "; }

   // импульс тел
   double impulse = BodyImpulse(sym, tf, 5);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(point <= 0.0) point = 1e-10;
   double imp_pts = impulse / point;
   if(imp_pts > 20)  { s.buy  += MathMin(4.0, imp_pts / 40.0); s.reason += tag + "imp↑ "; }
   if(imp_pts < -20) { s.sell += MathMin(4.0, -imp_pts / 40.0); s.reason += tag + "imp↓ "; }

   // наклон close
   double slope = CloseSlope(sym, tf, 4);
   double sl_pts = slope / point;
   if(sl_pts > 15)  { s.buy  += 1.5; s.reason += tag + "slope↑ "; }
   if(sl_pts < -15) { s.sell += 1.5; s.reason += tag + "slope↓ "; }

   // доля бычьих свечей
   double br = BullRatio(sym, tf, 8);
   if(br >= 0.625) { s.buy  += 2.0; s.reason += tag + "maj↑ "; }
   if(br <= 0.375) { s.sell += 2.0; s.reason += tag + "maj↓ "; }

   // классические паттерны
   if(IsHammer(cur))          { s.buy  += 3.0; s.reason += tag + "hammer "; }
   if(IsShootingStar(cur))    { s.sell += 3.0; s.reason += tag + "star "; }
   if(IsBullEngulf(prev, cur)){ s.buy  += 4.0; s.reason += tag + "eng↑ "; }
   if(IsBearEngulf(prev, cur)){ s.sell += 4.0; s.reason += tag + "eng↓ "; }
   if(MorningStarLike(sym, tf)){ s.buy  += 3.0; s.reason += tag + "mStar "; }
   if(EveningStarLike(sym, tf)){ s.sell += 3.0; s.reason += tag + "eStar "; }
   if(ThreeSoldiers(sym, tf)) { s.buy  += 3.5; s.reason += tag + "3sol "; }
   if(ThreeCrows(sym, tf))    { s.sell += 3.5; s.reason += tag + "3crow "; }
   if(StructureBull(sym, tf)) { s.buy  += 2.5; s.reason += tag + "HHHL "; }
   if(StructureBear(sym, tf)) { s.sell += 2.5; s.reason += tag + "LHLL "; }
  }

//+------------------------------------------------------------------+
KnowledgeScore EvaluateKnowledge(const string sym,
                                 const ENUM_TIMEFRAMES signal_tf,
                                 const bool trend_up,
                                 const bool trend_down)
  {
   KnowledgeScore s;
   s.buy = 0; s.sell = 0; s.reason = "";

   // Голоса EMA с графика анализа
   if(trend_up)   { s.buy  += 4.0; s.reason += "EMA↑ "; }
   if(trend_down) { s.sell += 4.0; s.reason += "EMA↓ "; }

   // Мульти-ТФ: быстрый + сигнал + старший
   AddTFVotes(sym, PERIOD_M5,  "M5:", s);
   AddTFVotes(sym, signal_tf,  "SIG:", s);          // обычно M15
   AddTFVotes(sym, PERIOD_H1,  "H1:", s);

   // Цена относительно недавнего mid диапазона H1
   double h[], l[], c[];
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);
   ArraySetAsSeries(c, true);
   if(CopyHigh(sym, PERIOD_H1, 1, 20, h) >= 20 &&
      CopyLow(sym, PERIOD_H1, 1, 20, l) >= 20 &&
      CopyClose(sym, PERIOD_H1, 1, 1, c) >= 1)
     {
      double hi = h[ArrayMaximum(h, 0, 20)];
      double lo = l[ArrayMinimum(l, 0, 20)];
      double mid = (hi + lo) * 0.5;
      if(c[0] > mid) { s.buy  += 2.0; s.reason += "aboveMid "; }
      else           { s.sell += 2.0; s.reason += "belowMid "; }
     }

   if(s.reason == "")
      s.reason = "neutral";
   return s;
  }

//+------------------------------------------------------------------+
// ВСЕГДА выбирает BUY или SELL — без дефолта в одну сторону.
void KnowledgeForceDir(const KnowledgeScore &ks,
                       ENUM_ORDER_TYPE &type,
                       string &reason)
  {
   // крошечный тай-брейкер по времени — не смещать в SELL
   double buy  = ks.buy;
   double sell = ks.sell;

   if(buy > sell)
     {
      type = ORDER_TYPE_BUY;
      reason = StringFormat("PRED BUY %.1f>%.1f | %s", buy, sell, ks.reason);
      return;
     }
   if(sell > buy)
     {
      type = ORDER_TYPE_SELL;
      reason = StringFormat("PRED SELL %.1f>%.1f | %s", sell, buy, ks.reason);
      return;
     }

   // Полный тай: смотрим минутный импульс — иначе BUY (не SELL!)
   // но честнее: использовать последний закрытый тик mid change — здесь M1 body
   // Если совсем ровно — buy как нейтральный bias вверх рынка в долгосрок FX редко нужен;
   // правильнее чередовать? Нет — используем знак BodyImpulse M5.
   // (передаём через reason без symbol — вызывающий ResolveDir должен передать tie-break)
   type = ORDER_TYPE_BUY;
   reason = StringFormat("PRED TIE→BUY %.1f=%.1f | %s", buy, sell, ks.reason);
  }

//+------------------------------------------------------------------+
void KnowledgeForceDirWithTieBreak(const string sym,
                                   const KnowledgeScore &ks,
                                   ENUM_ORDER_TYPE &type,
                                   string &reason)
  {
   if(ks.buy > ks.sell + 0.05)
     {
      type = ORDER_TYPE_BUY;
      reason = StringFormat("PRED BUY %.1f>%.1f | %s", ks.buy, ks.sell, ks.reason);
      return;
     }
   if(ks.sell > ks.buy + 0.05)
     {
      type = ORDER_TYPE_SELL;
      reason = StringFormat("PRED SELL %.1f>%.1f | %s", ks.sell, ks.buy, ks.reason);
      return;
     }

   double imp = BodyImpulse(sym, PERIOD_M5, 3);
   if(imp >= 0.0)
     {
      type = ORDER_TYPE_BUY;
      reason = StringFormat("PRED TIE→BUY(M5imp) %.1f/%.1f | %s", ks.buy, ks.sell, ks.reason);
     }
   else
     {
      type = ORDER_TYPE_SELL;
      reason = StringFormat("PRED TIE→SELL(M5imp) %.1f/%.1f | %s", ks.buy, ks.sell, ks.reason);
     }
  }

#endif
//+------------------------------------------------------------------+
