// 地図資産の再生成専用。通常のビルドとアプリ実行にNode.jsは不要。
const fs = require('fs'), path = require('path'), cp = require('child_process'), crypto = require('crypto');
const root = path.dirname(__dirname), cache = path.join(root, '.cache');
fs.mkdirSync(cache, { recursive: true });
const sources = [
 ['d3.cjs','https://cdn.jsdelivr.net/npm/d3@7.9.0/dist/d3.min.js'],
 ['topojson.cjs','https://cdn.jsdelivr.net/npm/topojson-client@3.1.0/dist/topojson-client.min.js'],
 ['world.json','https://cdn.jsdelivr.net/npm/world-atlas@2.0.2/countries-110m.json'],
 ['iso-codes.json','https://cdn.jsdelivr.net/npm/i18n-iso-countries@7.14.0/codes.json']
];
const lock = JSON.parse(fs.readFileSync(path.join(__dirname,'map-sources.json')));
for (const [name,url] of sources) {
 const file=path.join(cache,name);
 if(!fs.existsSync(file)) cp.execFileSync('curl',['--fail','--silent','--show-error','--location',url,'-o',file]);
 if(crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')!==lock[name]) throw Error(name+' チェックサム不一致');
}
const d3=require(path.join(cache,'d3.cjs')),topo=require(path.join(cache,'topojson.cjs'));
const numericToISO=new Map(JSON.parse(fs.readFileSync(path.join(cache,'iso-codes.json'))).map(row=>[row[2],row[0]]));
const world=JSON.parse(fs.readFileSync(path.join(cache,'world.json')));
const features=topo.feature(world,world.objects.countries).features.filter(f=>f.id!=='010');
const mainland=f=>f.geometry.type==='MultiPolygon'?f.geometry.coordinates.map(coordinates=>({type:'Polygon',coordinates})).sort((a,b)=>d3.geoArea(b)-d3.geoArea(a))[0]:f;
const japan=d3.geoCentroid(mainland(features.find(f=>f.id==='392')));
const projection=d3.geoNaturalEarth1().rotate([-japan[0],0]).fitExtent([[12,12],[788,354]],{type:'Sphere'}),geoPath=d3.geoPath(projection).digits(1);
const countries=features.map(f=>({code:numericToISO.get(f.id)||f.properties.name,path:geoPath(f),point:projection(d3.geoCentroid(mainland(f))).map(n=>+n.toFixed(1))}));
const data={countries,graticule:geoPath(d3.geoGraticule10()),home:projection(japan).map(n=>+n.toFixed(1))};
fs.writeFileSync(path.join(root,'Resources/Dashboard/world-map.js'),'// Natural Earth / world-atlas 2.0.2を日本中心へ投影。scripts/build_map.cjsで再生成。\nwindow.HoneyObsMap = '+JSON.stringify(data)+';\n');
console.log('地図生成:',countries.length,'か国・地域');
