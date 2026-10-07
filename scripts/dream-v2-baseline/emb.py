import sys,os,json,numpy as np
sys.path.insert(0,os.path.expanduser('~/brain/engine')); import semantic
d=json.load(open('ins.json'))
v=np.array(semantic.embed([x['title']+'. '+x['body'][:400] for x in d]),dtype=np.float32)
v/=np.linalg.norm(v,axis=1,keepdims=True); np.save('v.npy',v); print(semantic.MODEL_NAME, v.shape)
