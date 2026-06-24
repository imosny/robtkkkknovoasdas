
#property strict
#property version   "1.00"
#property description "XAUUSD EA V1.0 - Research implementation based on discussed specification"

#include <Trade/Trade.mqh>
CTrade trade;

input double RiskPercent=1.0;
input int StartHourUTC=8;
input int EndHourUTC=16;
input int MaxSpreadPoints=30;
input int OpportunitiesPerMonth=4;

int OpportunitiesRemaining=4;
datetime LastBar=0;
datetime LastTradeDay=0;

bool IsNewBar()
{
   datetime t=iTime(_Symbol,PERIOD_M15,0);
   if(t!=LastBar){ LastBar=t; return true; }
   return false;
}

bool IsTradingTimeUTC()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(),dt);
   return (dt.hour>=StartHourUTC && dt.hour<EndHourUTC);
}

bool TradedToday()
{
   MqlDateTime a,b;
   TimeToStruct(TimeGMT(),a);
   TimeToStruct(LastTradeDay,b);
   return (a.year==b.year && a.mon==b.mon && a.day==b.day);
}

double EMAValue(ENUM_TIMEFRAMES tf,int period,int shift=1)
{
   int h=iMA(_Symbol,tf,period,0,MODE_EMA,PRICE_CLOSE);
   double buf[];
   if(CopyBuffer(h,0,shift,1,buf)<=0) return 0;
   return buf[0];
}

double RSIValue(int shift=1)
{
   int h=iRSI(_Symbol,PERIOD_M15,14,PRICE_CLOSE);
   double b[];
   if(CopyBuffer(h,0,shift,1,b)<=0) return 0;
   return b[0];
}

double ATRValue(int shift=1)
{
   int h=iATR(_Symbol,PERIOD_M15,14);
   double b[];
   if(CopyBuffer(h,0,shift,1,b)<=0) return 0;
   return b[0];
}

double ADXValue(int shift=1)
{
   int h=iADX(_Symbol,PERIOD_M15,14);
   double b[];
   if(CopyBuffer(h,0,shift,1,b)<=0) return 0;
   return b[0];
}

bool BuySignal()
{
   double ema50=EMAValue(PERIOD_H4,50);
   double ema200=EMAValue(PERIOD_H4,200);
   double ema50old=EMAValue(PERIOD_H4,50,6);
   if(!(ema50>ema200 && ema50>ema50old)) return false;

   double rsi=RSIValue();
   double adx=ADXValue();
   if(rsi<50 || rsi>65 || adx<=25) return false;

   double ema20=EMAValue(PERIOD_M15,20);
   double o=iOpen(_Symbol,PERIOD_M15,1);
   double c=iClose(_Symbol,PERIOD_M15,1);
   double h=iHigh(_Symbol,PERIOD_M15,1);
   double l=iLow(_Symbol,PERIOD_M15,1);

   if(l>ema20) return false;
   if(c<=ema20) return false;

   double body=(c-o);
   double range=(h-l);
   if(body<=0 || range<=0) return false;
   if(body/range<0.60) return false;

   return true;
}

bool SellSignal()
{
   double ema50=EMAValue(PERIOD_H4,50);
   double ema200=EMAValue(PERIOD_H4,200);
   double ema50old=EMAValue(PERIOD_H4,50,6);
   if(!(ema50<ema200 && ema50<ema50old)) return false;

   double rsi=RSIValue();
   double adx=ADXValue();
   if(rsi<35 || rsi>50 || adx<=25) return false;

   double ema20=EMAValue(PERIOD_M15,20);
   double o=iOpen(_Symbol,PERIOD_M15,1);
   double c=iClose(_Symbol,PERIOD_M15,1);
   double h=iHigh(_Symbol,PERIOD_M15,1);
   double l=iLow(_Symbol,PERIOD_M15,1);

   if(h<ema20) return false;
   if(c>=ema20) return false;

   double body=(o-c);
   double range=(h-l);
   if(body<=0 || range<=0) return false;
   if(body/range<0.60) return false;

   return true;
}

double CalculateLot(double stopDistance)
{
   double riskMoney=AccountInfoDouble(ACCOUNT_BALANCE)*(RiskPercent/100.0);
   double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double lot=riskMoney/(stopDistance/tickValue);
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   if(lot<minLot) lot=minLot;
   return NormalizeDouble(lot,2);
}

int OnInit()
{
   OpportunitiesRemaining=OpportunitiesPerMonth;
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   if(!IsNewBar()) return;
   if(!IsTradingTimeUTC()) return;
   if(TradedToday()) return;
   if(PositionSelect(_Symbol)) return;
   if(OpportunitiesRemaining<=0) return;

   int spread=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   if(spread>MaxSpreadPoints) return;

   double atr=ATRValue();
   if(atr<=0) return;

   double lot=CalculateLot(atr);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);

   if(BuySignal())
   {
      trade.Buy(lot,_Symbol,ask,ask-atr,ask+(atr*1.2));
      LastTradeDay=TimeGMT();
   }

   if(SellSignal())
   {
      trade.Sell(lot,_Symbol,bid,bid+atr,bid-(atr*1.2));
      LastTradeDay=TimeGMT();
   }
}
