import {test} from 'node:test';import assert from 'node:assert/strict';import {serveMedia,jpegDimensions,boundedBytes} from '../media/handler.mjs';
const path='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.jpg',bytes=new Uint8Array(Buffer.from('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAAKABQDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAb/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAb/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCGAXqJAAf/2Q==','base64'));
test('public media gateway bounds paths, publication and raster bytes',async()=>{let read=0;const req=new Request('https://media.example.invalid/?shop=shop&image=hero'),deps={lookup:async()=>path,read:async()=>{read++;return bytes}};assert.deepEqual(jpegDimensions(bytes),{width:20,height:10});const r=await serveMedia(req,deps);assert.equal(r.status,200);assert.equal(r.headers.get('cache-control'),'no-store, max-age=0');assert.equal((await serveMedia(req,{...deps,lookup:async()=>null})).status,404);assert.equal((await serveMedia(req,{...deps,lookup:async()=>path+'/../secret'})).status,404);assert.equal(read,1);assert.equal((await serveMedia(req,{...deps,read:async()=>new Uint8Array([1,2,3])})).status,404);assert.equal((await serveMedia(new Request(req.url,{method:'POST'}),deps)).status,405);assert.equal(await boundedBytes(new Response(new Uint8Array(2000001),{headers:{'content-type':'image/jpeg'}})),null)});
test('JPEG framing rejects header-only, truncated scan and trailing bytes',()=>{
 const headerOnly=new Uint8Array([255,216,255,192,0,11,8,0,10,0,20,1,1,17,0,255,217]);
 assert.equal(jpegDimensions(headerOnly),null);
 assert.equal(jpegDimensions(bytes.slice(0,-2)),null);
 assert.equal(jpegDimensions(Uint8Array.from([...bytes,0])),null);
 const scan=bytes.findIndex((x,i)=>x===255&&bytes[i+1]===218);
 const start=scan+2+bytes[scan+2]*256+bytes[scan+3];
 assert.equal(jpegDimensions(Uint8Array.from([...bytes.slice(0,start),255,217])),null);
 const large=bytes.slice(),sof=large.findIndex((x,i)=>x===255&&large[i+1]===192);large[sof+7]=7;large[sof+8]=0;
 assert.equal(jpegDimensions(large),null);
});

test('bounded media rejects partial, encoded, malformed and inconsistent responses',async()=>{
 const h={'content-type':'image/jpeg'};
 for(const headers of [{'content-length':'NaN'},{'content-length':'0'},{'content-length':'2000001'},{'content-length':String(bytes.length+1)},{'content-length':String(bytes.length-1)},{'content-encoding':'gzip'}])assert.equal(await boundedBytes(new Response(bytes,{headers:{...h,...headers}})),null);
 assert.equal(await boundedBytes(new Response(bytes,{status:206,headers:h})),null);
 assert.deepEqual(await boundedBytes(new Response(bytes,{headers:{...h,'content-length':String(bytes.length)}})),bytes);
 assert.deepEqual(await boundedBytes(new Response(bytes,{headers:h})),bytes);
 let cancelled=false;const stream=new ReadableStream({pull(c){c.enqueue(new Uint8Array(2000001))},cancel(){cancelled=true}});
 assert.equal(await boundedBytes(new Response(stream,{headers:h})),null);assert.equal(cancelled,true);
});
