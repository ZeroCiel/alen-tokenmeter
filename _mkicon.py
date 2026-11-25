from PIL import Image, ImageDraw
img = Image.new('RGBA',(32,32),(22,24,29,255))
d = ImageDraw.Draw(img)
d.rounded_rectangle([3,5,29,10], 3, fill=(61,220,132,255))
d.rounded_rectangle([3,13,19,18], 3, fill=(255,179,0,255))
d.rounded_rectangle([3,21,29,26], 3, fill=(255,82,82,255))
img.save(r'D:\Backup\Documents\deepseek-harness\TokenMeter\meter.ico', sizes=((32,32),(16,16)))
print('icon ok')
