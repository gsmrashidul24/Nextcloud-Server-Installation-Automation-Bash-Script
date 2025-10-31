
# 								®®®®®®®®®®®®®®®®®®®®®®®®®®®®®®®®®®®®®®®#
#   						®®®®®®®®®®®[DOCUMENTATION REPORT]®®®®®®®®®®®   
#									®®®®®®®®®®®®®®®®®®®®®®®®®®®®®®®®®®®®®®®®
																																		 										 
#	  	 			Nextcloud + Cloudflared AUTO INSTALLER DOCUMENTATION	  	 
#						****************************************************
																					 																				 			
# 														Created by Rasel-Tech	 															  
# 									Compatible with: Ubuntu 22.04 / 24.04	 									    
#										*************************************  																	 								 					 																						



📘 Nextcloud + Cloudflared Auto Installer Script বিশ্লেষণ রিপোর্ট

ফাইল: nextcloud_setup.sh
তৈরি করেছেন: Rasel-Tech
সিস্টেম সাপোর্ট: Ubuntu 22.04 / 24.04


🧠 মূল উদ্দেশ্য

এই স্ক্রিপ্টটি স্বয়ংক্রিয়ভাবে Nextcloud সার্ভার ইনস্টল ও কনফিগার করে, যার সাথে যুক্ত থাকে—

Apache2 + PHP 8.2-FPM

MariaDB + Redis

Cloudflare Tunnel (স্বয়ংক্রিয় DNS, SSL এবং Origin CA সার্টিফিকেটসহ)

Firewall, Fail2Ban, ও ক্রনজব হেলথ চেক

সম্পূর্ণ নিরাপত্তা ও অটো-রিকভারি ফিচার


⚙️ মূল বৈশিষ্ট্য (Features & Highlights)

🔐 ইন্টার‌্যাকটিভ ইনপুট (ডোমেইন, DB, API Token, ইমেইল, ইত্যাদি)

🌐 Cloudflare Tunnel API ইন্টিগ্রেশন

🧩 Apache + PHP 8.2-FPM Auto-tuning

💾 MariaDB + Redis কনফিগারেশন

⚡ Auto Memory Allocation (RAM ভিত্তিক)

🔒 TLS/SSL সার্টিফিকেট অটো ইস্যু (Cloudflare Origin CA)

🚀 System Hardening, Firewall, Fail2Ban ও Cron Health Check


🧩 স্ক্রিপ্টের প্রধান ধাপসমূহ

1️⃣ Root Check & Logging

Root না হলে স্ক্রিপ্ট থেমে যায়।

প্রতিটি Error লগ হয় /var/log/nextcloud-install.log-এ।


2️⃣ User Input Section

নিচের তথ্যগুলো ইউজারের কাছ থেকে নেয়া হয়:

Domain Name

Tunnel Name

Nextcloud Admin Username/Password

Database Name, User, Password

Cloudflare API Token ও Zone ID

Optional Admin Email


Cloudflare Token Verify করা হয় API কলের মাধ্যমে ✅


3️⃣ System Preparation

apt update && apt full-upgrade -y

ইনস্টল করা প্যাকেজসমূহ:

curl, wget, vim, git, ufw, lsb-release,
apt-transport-https, ca-certificates, gnupg,
openssl, unzip, fail2ban, zip, coreutils

Timezone সেট করে ও NTP চালু করে।

RAM < 4GB হলে স্বয়ংক্রিয়ভাবে swap ফাইল তৈরি করে।


4️⃣ Data Directory

/mnt/nextcloud_data ডিরেক্টরি তৈরি করে

মালিকানা: www-data:www-data

পারমিশন: 750


5️⃣ Apache2 + PHP 8.2-FPM

mpm_event, proxy_fcgi, php-fpm কনফিগার

প্রয়োজনীয় PHP এক্সটেনশন ইনস্টল

RAM অনুযায়ী PHP memory_limit ও OPcache auto-tuning


6️⃣ Redis কনফিগারেশন

Redis Unix socket সক্রিয়

www-data গ্রুপে redis যোগ করা

Redis status check করে “Redis is up and running.” লগ করে ✅


7️⃣ MariaDB সেটআপ

mariadb-server ইনস্টল

Root ও ইউজার পাসওয়ার্ড সেট

Nextcloud Database তৈরি

RAM অনুযায়ী innodb_buffer_pool_size ও log_file_size অটো টিউন


8️⃣ Nextcloud ইনস্টলেশন

Nextcloud zip ডাউনলোড করে /var/www/html/nextcloud-এ ইনস্টল

Apache VirtualHost তৈরি

Headless ইনস্টলেশনের জন্য OCC কমান্ড চালায়

Trusted Domain, Redis, Overwrite settings কনফিগার করে


9️⃣ Cloudflare Tunnel Setup

API দিয়ে Tunnel তৈরি (headless)

যদি ব্যর্থ হয়, Manual JSON Import fallback

/etc/cloudflared/config.yml তৈরি করে


🔧 Cloudflare DNS Configuration

API দিয়ে CNAME রেকর্ড তৈরি করে:

<your-domain> → <tunnel_id>.cfargotunnel.com


🔐 Cloudflare Origin SSL Setup

Cloudflare API থেকে Origin CA সার্টিফিকেট ইস্যু

সার্টিফিকেট ও কী /etc/ssl/nextcloud এ সংরক্ষিত

Apache HTTPS vhost সেটআপ ✅


🔥 Firewall & Fail2ban

UFW → Allow ports 22, 80, 443

Fail2ban → SSH ও Nextcloud লগ মনিটর

SSH brute-force প্রতিরোধে rate-limit সেট


🧠 Cron & Health Check

www-data ইউজারের জন্য প্রতি ৫ মিনিটে Nextcloud cron.php রান

/etc/cron.daily/nextcloud_healthcheck

Apache2, MariaDB, Redis, Cloudflared স্বয়ংক্রিয়ভাবে মনিটর ও রিস্টার্ট করে

ভবিষ্যতে Telegram alert ইন্টিগ্রেশন করা যাবে (স্ক্রিপ্টে মন্তব্য আকারে আছে)।


🧹 Cleanup & Final Steps

সমস্ত সংবেদনশীল ভ্যারিয়েবল unset

apt clean

সার্ভিস স্ট্যাটাস চেক

শেষে রিবুট রিকমেন্ডেশন দেখায়


⚠️ সম্ভাব্য সমস্যা বা ঝুঁকি

🧠 Syntax									✅ ঠিক আছে
🔩 Variable Handling	  ✅ সব ঠিকভাবে quoted	
🧰 MariaDB Logic				✅ ঠিকভাবে কাজ করবে	
⚙️ Redis Socket					  ✅ fallback সিস্টেম সঠিক	
🔒 Cloudflare TLS				✅ TLS verify সক্রিয় (false সেট করা হয়েছে)	
📜 Base64 Dependency	✅ coreutils ইনস্টল হওয়ায় সমাধান	
🧾 Cloudflare API				 ✅ সঠিকভাবে verify করে	
🧱 Security Cleanup			✅ ঠিকভাবে কাজ করছে	


🔒 নিরাপত্তা ও স্থিতিশীলতা

✅ সক্রিয় সুরক্ষা ফিচার:

Fail2Ban brute-force প্রতিরোধ

Firewall Active

SSH rate-limit

TLS “Full (Strict)” মোড সাপোর্ট

Systemd restart policies

Sensitive data clear at end


📈 সারসংক্ষেপ মূল্যায়ন

⚙️ Logic Flow 				 	✅ শক্তিশালী
🧠 Syntax								 ✅ নিখুঁত
🌐 Cloudflare Tunnel	✅ স্থিতিশীল
🔐 TLS & SSL					 	✅ সুরক্ষিত
💾 Database							✅ স্থিতিশীল
⚡ Performance				  ✅ RAM টিউনিংসহ চমৎকার
🔥 Firewall / Fail2Ban	✅ কার্যকর


🏁 চূড়ান্ত রায়

✅ এটি একটি নিরাপদ, শক্তিশালী, এবং সম্পূর্ণ স্বয়ংক্রিয় Nextcloud ইনস্টলার স্ক্রিপ্ট।

> Cloudflare-এ অবশ্যই SSL/TLS Mode → Full (Strict) সেট করবে, তাহলেই end-to-end encryption সম্পূর্ণ হবে।

