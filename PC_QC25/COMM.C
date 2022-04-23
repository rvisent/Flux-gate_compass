// FLCOM.C - comunicazione con flux-gate mediante seriale su parallela
// RV080195
// nuovo protocollo RV210195

#include <stdio.h>
#include <conio.h>
#include <graph.h>
#include <math.h>

struct FLDATA
{
        int tx_x;
        int tx_y;
        int tx_3;
};

volatile long __far *pTick = (volatile long __far *)0x0000046CL;  // tick timer

#define PR_STAT 0x379   // printer status register
#define PR_CTRL 0x37A   // printer control register

#define ERR 1000        // fuori dal range -256..+255

int interroga(struct FLDATA *pData);

void main()
{
        struct FLDATA data;
        int n,err,x,y,fl=0,precX=0, precY=0;
        long t0;
        char s[80],ck;
        double direz, intens;

        _setvideomode(_VRES16COLOR);
        // leggi ogni 10 tick
        while (!kbhit())
        {
          t0 = *pTick + 10;
          while (*pTick < t0);
          if (!(n=interroga(&data)))
          {
            _settextcolor(7);
            _settextposition(2,1);
            sprintf(s,"tx_x = %2X  ", data.tx_x);
            _outtext(s);
            _settextposition(3,1);
            sprintf(s,"tx_y = %2X  ", data.tx_y);
            _outtext(s);
            _settextposition(4,1);
            sprintf(s,"tx_3 = %2X  ", data.tx_3);
            _outtext(s);

			// controlla MSB dei 3 byte
			err = 0;
			if (data.tx_x & 0x80) err = 1;
			if (data.tx_y & 0x80) err |= 2;
			if (!(data.tx_3 & 0x80)) err |= 4;
			data.tx_x &= 0x7F;
			data.tx_y &= 0x7F;
			
			// ricostruisci x,y dai 3 byte
			x = data.tx_x | ((int)data.tx_3 << 7);
			if (x & 0x100) x |= 0xFF00;	// negativo
			else x &= 0xFF;				// positivo
			y = data.tx_y | (((int)data.tx_3 << 5) & 0x180);
			if (y & 0x100) y |= 0xFF00;	// negativo
			else y &= 0xFF;				// positivo
            _settextposition(2,15);
            sprintf(s,"x = %4d   ", x);
            _outtext(s);
            _settextposition(3,15);
            sprintf(s,"y = %4d   ", y);
            _outtext(s);

			// checksum
			ck = data.tx_x+data.tx_y+(data.tx_3 & 0x0F);
			ck = ck+(ck<<3)+(ck<<6);
			if ((ck ^ data.tx_3) & 0x70) err |= 8;	// controlla i 3 bit
            _settextposition(5,1);
			if (err) _settextcolor(15);
            sprintf(s,"err  = %1X  ", err);
	        _outtext(s);
                
            // calcola direzione e intensita' del campo
            // occorre almeno un argomento non nullo per la direzione
           	intens = sqrt((double)x*x + (double)y*y);
            _settextcolor(14);
            _settextposition(9,1);
            sprintf(s,"intensita'= %6.2f  ",intens);
            _outtext(s);
            if (x || y)
            {
            	direz = atan2(x,y)*57.29578;
            	if (direz < 0.) direz += 360.;

	            _settextposition(8,1);
    	        sprintf(s,"direzione = %6.2f  ",direz);
        	    _outtext(s);
			}

			if (fl)
			{
				_settextposition(6,1);
            	_outtext("                                   ");
            	fl = 0;
            }
            
            // plot al centro dello schermo
            _setcolor(0);
            _moveto(320,240);
            _lineto(precX,precY);
            precX = 320+x;
            precY = 240-y;
            _setcolor(12);
            _moveto(320,240);
            _lineto(precX,precY);
            _setcolor(14);
            // segna riferimenti a passi di 45 gradi
            _setpixel(320,290); _setpixel(370,240);
            _setpixel(320,190); _setpixel(270,240);
            _setpixel(355,275); _setpixel(285,205);
            _setpixel(355,205); _setpixel(285,275);
          }
          else
          {
          	_settextcolor(12);
            _settextposition(6,1);
            sprintf(s,"errore di comunicazione, byte %d   ",n);
            _outtext(s);
            fl = 1;
          }
        }
        if (!getch()) getch();
        _setvideomode(_DEFAULTMODE);
}


int rdbyte()
{
        int i, k;
        unsigned char result=0;
        long t0;

        // si parte dal bit piu' significativo
        for (i=7; i>=0; i--)
        {
                // attendi ACK alto (fine ciclo precedente), max 55 ms
                t0 = *pTick+2;
                while (!(_inp(PR_STAT) & 0x40))
                        if (*pTick > t0) return ERR; // timeout 1

                // abbassa il pin STROBE (logica inversa -> scrivi 1)
                _outp(PR_CTRL, 1);

                // attendi ACK basso , max 55 ms
                t0 = *pTick+2;
                while ((k=_inp(PR_STAT)) & 0x40)
                        if (*pTick > t0) return ERR+1; // timeout 2

                // alza il pin STROBE
                _outp(PR_CTRL,0);

                // leggi il bit (logica inversa)
                if (!(k & 0x80)) result |= 1<<i;

        }
        return result;  // estendi in segno a int
}


int interroga(struct FLDATA *pData)
{
        int b;

        if ((b=rdbyte()) >= ERR) return 1;
        else pData->tx_x = b;
        if ((b=rdbyte()) >= ERR) return 2;
        else pData->tx_y = b;
        if ((b=rdbyte()) >= ERR) return 3;
        else pData->tx_3 = b;
        return 0;
}
