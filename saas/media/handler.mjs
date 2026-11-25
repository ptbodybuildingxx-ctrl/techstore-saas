// Public image proxy; paths resolved by server only.
const id=/^[a-z0-9-]{1,40}$/,slug=/^[a-z][a-z0-9-]{2,39}$/,uuid='[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}',pathPattern=new RegExp('^'+uuid+'/'+uuid+'\\.jpg$');
// Validate marker structure and scan framing, not the compressed pixel data itself.
export function jpegDimensions(b){
 if(!(b instanceof Uint8Array)||b.length<12||b.length>2000000||b[0]!==255||b[1]!==216)return null;
 let i=2,frame=null,components=null,scans=0,inScan=false,scanData=false;
 while(i<b.length){
  if(inScan){
   if(b[i++]!==255){scanData=true;continue}
   while(i<b.length&&b[i]===255)i++;
   if(i>=b.length)return null;
   if(b[i]===0){i++;scanData=true;continue}
   if(b[i]>=208&&b[i]<=215){i++;continue}
   if(!scanData)return null;
   inScan=false;i--; // Re-read the marker prefix.
  }
  if(b[i++]!==255)return null;
  while(i<b.length&&b[i]===255)i++;
  if(i>=b.length)return null;
  const m=b[i++];
  if(m===217)return frame&&scans>0&&i===b.length?frame:null;
  if(m===0||m===216||m===1||(m>=208&&m<=215)||i+2>b.length)return null;
  const len=b[i]*256+b[i+1],end=i+len;
  if(len<2||end>b.length)return null;
  if([192,193,194].includes(m)){
   if(frame||len<11||b[i+2]!==8)return null;
   const height=b[i+3]*256+b[i+4],width=b[i+5]*256+b[i+6],count=b[i+7];
   if(!width||!height||width>1600||height>1600||![1,3,4].includes(count)||len!==8+3*count)return null;
   components=new Set(Array.from({length:count},(_,j)=>b[i+8+3*j]));
   if(components.size!==count)return null;
   frame={width,height};
  }else if(m>=192&&m<=207&&![196,204].includes(m))return null;
  if(m===218){
   if(!frame||len<8)return null;
   const count=b[i+2],ids=Array.from({length:count},(_,j)=>b[i+3+2*j]);
   if(!count||count>components.size||len!==6+2*count||new Set(ids).size!==count||ids.some(x=>!components.has(x)))return null;
   scans++;inScan=true;scanData=false;
  }
  i=end;
 }
 return null;
}
const common={'Cache-Control':'no-store, max-age=0','X-Content-Type-Options':'nosniff','Content-Security-Policy':"default-src 'none'; sandbox",'Cross-Origin-Resource-Policy':'cross-origin'};
const missing=()=>new Response(null,{status:404,headers:common});
export async function serveMedia(req,{lookup,read}){try{if(req.method!=='GET')return new Response(null,{status:405,headers:{...common,Allow:'GET'}});const q=new URL(req.url).searchParams,s=q.get('shop'),i=q.get('image');if(!s||!slug.test(s)||!i||!id.test(i)||q.size!==2)return missing();const path=await lookup(s,i);if(typeof path!=='string'||!pathPattern.test(path))return missing();const bytes=await read(path);if(!jpegDimensions(bytes))return missing();return new Response(bytes,{status:200,headers:{...common,'Content-Type':'image/jpeg','Content-Length':String(bytes.length),'Content-Disposition':'inline; filename="image.jpg"'}})}catch{return missing()}}
export async function boundedBytes(r){if(!r.ok||r.headers.get('content-type')?.split(';')[0]!=='image/jpeg'||!r.body||Number(r.headers.get('content-length'))>2000000)return null;const reader=r.body.getReader(),chunks=[];let total=0;try{while(true){const {value,done}=await reader.read();if(done)break;total+=value.length;if(total>2000000){await reader.cancel();return null}chunks.push(value)}}finally{reader.releaseLock()}const result=new Uint8Array(total);let offset=0;for(const chunk of chunks){result.set(chunk,offset);offset+=chunk.length}return result}
