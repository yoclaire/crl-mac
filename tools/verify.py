import sys, time, random
sys.path.insert(0, sys.argv[1]); from redb import REDB, dump_all
for p in sys.argv[2:]:
    t = time.time(); db = REDB(p); es = dump_all(db)
    bad = [n for n in random.Random(1).sample(range(db.nentries), min(200, db.nentries)) if db.entry(n) != es[n]]
    print(p.split('/')[-1], 'declared', db.nentries, 'decoded', len(es), 'mismatch', len(bad),
          'bytes', sum(map(len, es)), 'last:', es[-1][:60], f'{time.time()-t:.1f}s')
