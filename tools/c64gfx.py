import sys
from PIL import Image

def hires(data, off, cols=40, rows=25, scale=2):
    w,h=cols*8,rows*8
    im=Image.new('RGB',(w,h),(0,0,0)); px=im.load()
    for cy in range(rows):
        for cx in range(cols):
            base=off+(cy*cols+cx)*8
            for y in range(8):
                if base+y>=len(data): return im.resize((w*scale,h*scale),Image.NEAREST)
                b=data[base+y]
                for x in range(8):
                    if b&(0x80>>x): px[cx*8+x,cy*8+y]=(255,255,255)
    return im.resize((w*scale,h*scale),Image.NEAREST)

def charset(data, off, count=256, per=32, scale=3):
    rows=(count+per-1)//per
    im=Image.new('RGB',(per*8,rows*8),(0,0,60)); px=im.load()
    for i in range(count):
        cx,cy=(i%per)*8,(i//per)*8
        for y in range(8):
            if off+i*8+y>=len(data): break
            b=data[off+i*8+y]
            for x in range(8):
                if b&(0x80>>x): px[cx+x,cy+y]=(255,255,255)
    return im.resize((per*8*scale,rows*8*scale),Image.NEAREST)

if __name__=='__main__':
    mode,path,off,out=sys.argv[1],sys.argv[2],int(sys.argv[3],0),sys.argv[4]
    d=open(path,'rb').read()
    (hires(d,off) if mode=='bmp' else charset(d,off)).save(out)
    print(out)
