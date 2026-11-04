"""Pinned original open-source archives; all extracted code stays in Downloads."""
from pathlib import Path,PurePosixPath
import datetime,hashlib,json,os,shutil,sys,urllib.request,zipfile
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT))
from sketchup_adapter.registry import Registry,atomic_json
stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
BASE=Path.home()/'Downloads/IngeTrazo-Adapter-Test-Plugins'/('open-source-'+stamp);BASE.mkdir(parents=True)
results=[]
for item in json.loads((ROOT/'tests/open_source_repositories.json').read_text()):
    case=item['repo'].split('/')[-1].replace('-','_');archive=BASE/(case+'-'+item['commit'][:12]+'.zip')
    url=f"https://codeload.github.com/{item['repo']}/zip/{item['commit']}"
    request=urllib.request.Request(url,headers={'User-Agent':'IngeTrazo-Adapter-Compatibility-QA'})
    with urllib.request.urlopen(request,timeout=60) as response,archive.open('wb') as output:
        size=0
        while chunk:=response.read(1024*1024):
            size+=len(chunk)
            if size>200*1024*1024:raise ValueError('Archive exceeds 200 MiB')
            output.write(chunk)
    extracted=BASE/case/'original';extracted.mkdir(parents=True)
    with zipfile.ZipFile(archive) as bundle:
        if len(bundle.infolist())>30000 or sum(i.file_size for i in bundle.infolist())>1024**3:raise ValueError('Unbounded fixture')
        for entry in bundle.infolist():
            path=PurePosixPath(entry.filename)
            if path.is_absolute() or '..' in path.parts or '\\' in entry.filename or any(':' in p for p in path.parts):raise ValueError('Unsafe archive path')
            target=extracted.joinpath(*path.parts)
            if entry.is_dir():target.mkdir(parents=True,exist_ok=True)
            else:
                target.parent.mkdir(parents=True,exist_ok=True)
                with bundle.open(entry) as source,target.open('wb') as output:shutil.copyfileobj(source,output)
    source=next(extracted.iterdir())
    loaders=sorted(source.rglob('*.rb'))
    likely=[str(p.relative_to(source)) for p in loaders if p.parent.name in ('src','src_rb','Plugins') or p.parent==source]
    licenses=[str(p.relative_to(source)) for p in source.rglob('*') if p.is_file() and p.name.lower().startswith(('license','licence','copying'))]
    item=dict(item,case=case,archive=str(archive),archive_sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
        source=str(source),profile=str(BASE/case/'profile'),loader_candidates=likely,license_files=licenses,
        rbe_files=len(list(source.rglob('*.rbe'))),ruby_files=len(loaders),status='downloaded')
    results.append(item)
    hashes={str(p.relative_to(source)):hashlib.sha256(p.read_bytes()).hexdigest() for p in source.rglob('*') if p.is_file()}
    atomic_json(BASE/case/'source-hashes.json',hashes)
    print(case,item['ruby_files'],'Ruby files',likely,flush=True)
manifest=dict(downloads=str(BASE),results=results,production_registry_modified=False,sketchup_executed=False)
atomic_json(BASE/'manifest.json',manifest);atomic_json(ROOT/'verification/open-source-downloads.json',manifest)
(BASE/'README.txt').write_text('Original pinned test downloads, extracted sources, profiles and output files.\n'
    'No fixture is enabled in the production registry. This whole folder can be deleted after testing.\n',encoding='utf-8')
print('Downloads:',BASE,flush=True)
