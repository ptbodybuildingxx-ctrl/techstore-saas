// One-shot, local camera barcode scan. Never records or uploads video.
export function createBarcodeCamera({startButton,stopButton,video,status,input,form,tr,allowed}){
 let generation=0,stream=null,timer=null,deadline=null,active=false;
 const say=s=>{status.textContent=tr(s)};
 function stop(){generation++;active=false;clearTimeout(timer);clearTimeout(deadline);stream?.getTracks().forEach(t=>t.stop());stream=null;video.pause();video.srcObject=null;video.hidden=true;stopButton.hidden=true;startButton.disabled=!allowed()}
 function sync(){if(active&&(!allowed()||document.hidden||!startButton.getClientRects().length))stop();startButton.disabled=active||!allowed()}
 async function start(){
  if(!allowed()||active)return;
  if(!globalThis.BarcodeDetector||!navigator.mediaDevices?.getUserMedia){say('قراءة الباركود بالكاميرا غير مدعومة؛ استخدم الماسح أو أدخل الرمز.');return}
  const token=++generation;active=true;sync();stopButton.hidden=false;say('وجّه الكاميرا نحو الباركود');
  try{
   const detector=new BarcodeDetector();
   const acquired=await navigator.mediaDevices.getUserMedia({video:{facingMode:{ideal:'environment'}},audio:false});
   if(token!==generation||!allowed()||document.hidden||!startButton.getClientRects().length){acquired.getTracks().forEach(t=>t.stop());if(token===generation)stop();return}
   stream=acquired;video.srcObject=stream;video.hidden=false;await video.play();
   if(token!==generation)return;
   deadline=setTimeout(()=>{if(token===generation){stop();say('انتهت مهلة الكاميرا')}},60000);
   async function scan(){
    if(token!==generation)return;
    if(!allowed()||document.hidden||!startButton.getClientRects().length){stop();return}
    try{const hits=await detector.detect(video);if(token!==generation)return;
     const code=hits.find(x=>typeof x.rawValue==='string'&&x.rawValue.trim()&&x.rawValue.trim().length<=80)?.rawValue.trim();
     if(code){stop();input.value=code;say('تمت قراءة الباركود');if(allowed())form.requestSubmit();return}
    }catch{if(token===generation){stop();say('تعذرت قراءة الباركود بالكاميرا')}return}
    if(token===generation)timer=setTimeout(scan,200)
   }
   await scan()
  }catch{if(token===generation){stop();say('تعذر فتح الكاميرا؛ تحقق من إذن المتصفح.')}}
 }
 startButton.addEventListener('click',start);stopButton.addEventListener('click',()=>{stop();status.textContent=''});
 document.addEventListener('visibilitychange',()=>{if(document.hidden)stop()});
 window.addEventListener('pagehide',stop);
 return {stop,sync}
}
