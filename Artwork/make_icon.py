from PIL import Image, ImageDraw, ImageFilter
from pathlib import Path
import subprocess

repo_root = Path(__file__).resolve().parents[1]
root = repo_root / '.build' / 'AppIcon.iconset'
root.mkdir(parents=True, exist_ok=True)
N = 1024
bg = Image.new('RGBA', (N,N), (0,0,0,0))
mask = Image.new('L',(N,N),0)
ImageDraw.Draw(mask).rounded_rectangle((42,42,982,982),radius=215,fill=255)
for y in range(N):
    for x in range(N):
        u = (x + 0.55*y) / (1.55*N)
        bg.putpixel((x,y),(int(246-24*u),int(122-41*u),int(70-24*u),255))
bg.putalpha(mask)

def tilted_card(size, angle, pos, paint):
    card = Image.new('RGBA', size, (0,0,0,0))
    paint(card)
    rotated = card.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True)
    shadow = Image.new('RGBA',bg.size,(0,0,0,0))
    shadow.alpha_composite(rotated, pos)
    shadow.putalpha(shadow.getchannel('A').filter(ImageFilter.GaussianBlur(24)).point(lambda v: int(v*0.28)))
    bg.alpha_composite(shadow, (0,22))
    bg.alpha_composite(rotated,pos)

def draw_back(card):
    d=ImageDraw.Draw(card)
    d.rounded_rectangle((12,12,446,550),radius=65,fill=(25,49,62,255))
    d.rounded_rectangle((45,45,413,517),radius=38,outline=(255,255,255,30),width=7)
    colors=[(255,246,230,235),(255,246,230,180),(255,246,230,125)]
    for row in range(3):
        for col in range(3):
            x=94+col*85; y=142+row*85
            d.rounded_rectangle((x,y,x+59,y+59),radius=13,fill=colors[min(col+row//2,2)])

def draw_front(card):
    d=ImageDraw.Draw(card)
    d.rounded_rectangle((12,12,458,560),radius=62,fill=(255,248,233,255))
    d.rounded_rectangle((48,48,422,524),radius=37,fill=(238,237,216,255))
    d.ellipse((262,110,372,220),fill=(248,167,81,255))
    d.polygon([(48,420),(174,265),(281,395),(345,313),(422,410),(422,524),(48,524)],fill=(39,94,100,255))
    d.polygon([(48,490),(194,358),(306,477),(363,420),(422,485),(422,524),(48,524)],fill=(20,53,68,255))
    d.rounded_rectangle((55,55,415,517),radius=30,outline=(255,255,255,120),width=8)

tilted_card((460,562),13,(80,190),draw_back)
tilted_card((470,572),-9,(328,184),draw_front)
# A small transition glint sits in the gap between the cards.
d=ImageDraw.Draw(bg)
d.line([(341,660),(403,660)],fill=(255,249,235,240),width=20)
d.polygon([(403,627),(447,660),(403,693)],fill=(255,249,235,240))
bg.save(repo_root / 'Resources' / 'BrandMark.png')
for size in (16,32,128,256,512,1024):
    im=bg.resize((size,size),Image.Resampling.LANCZOS)
    names={
        16:['icon_16x16.png'],
        32:['icon_16x16@2x.png','icon_32x32.png'],
        128:['icon_128x128.png'],
        256:['icon_128x128@2x.png','icon_256x256.png'],
        512:['icon_256x256@2x.png','icon_512x512.png'],
        1024:['icon_512x512@2x.png']
    }[size]
    for name in names: im.save(root/name)
bg.resize((64,64),Image.Resampling.LANCZOS).save(root/'icon_32x32@2x.png')
subprocess.run(['iconutil', '-c', 'icns', '-o', str(repo_root / 'Resources' / 'AppIcon.icns'), str(root)], check=True)
