// One service worker per shop path. No cached credentials or authenticated pages.
self.addEventListener('push',event=>{let tag='techstore';try{const v=event.data?.json();if(typeof v?.tag==='string'&&/^ts-[a-f0-9-]{36}$/i.test(v.tag))tag=v.tag}catch{}event.waitUntil(self.registration.showNotification('TechStore',{body:'لديك تحديث جديد في حسابك.',tag}))});
self.addEventListener('notificationclick',event=>{event.notification.close();event.waitUntil(self.clients.openWindow(self.registration.scope))});
