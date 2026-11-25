#!/usr/bin/env bash
# Самопроверка КТ «Архитектура». Запуск из папки ~/devops-arch:  bash check-arch.sh
ok=0; total=0
pass() { ok=$((ok+1)); total=$((total+1)); echo "[OK]   $1"; }
fail() { total=$((total+1)); echo "[FAIL] $1"; }
info() { echo "       $1"; }
has()  { grep -q -- "$2" "$1" 2>/dev/null; }
# блок сервиса из docker-compose.yml (от "  имя:" до следующего сервиса)
svc()  { awk -v s="  $1:" '$0==s{f=1;next} f&&/^  [a-z]/{f=0} f&&/^[a-z]/{f=0} f' docker-compose.yml; }

FP=$(cat architecture.md 2>/dev/null | cksum | cut -d' ' -f1)
echo "=== КТ Архитектура | $(git config user.name 2>/dev/null) | $(date '+%Y-%m-%d %H:%M:%S') | отпечаток $FP ==="

echo "--- 1. Файлы проекта"
for f in architecture.md docker-compose.yml gateway/nginx.conf .env.example .gitignore README.md; do
  [ -f "$f" ] && pass "есть $f" || fail "нет $f"
done
n=$(ls diagrams/*.png 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -ge 3 ] && pass "картинок схем в diagrams/: $n" || fail "картинок схем в diagrams/: $n (нужно минимум 3)"

echo "--- 2. Схемы C4 в architecture.md"
m=$(grep -c '^```mermaid' architecture.md 2>/dev/null)
[ "${m:-0}" -ge 3 ] && pass "блоков mermaid: $m" || fail "блоков mermaid: ${m:-0} (нужно минимум 3)"
for t in C4Context C4Container C4Component; do has architecture.md "$t" && pass "есть уровень $t" || fail "нет уровня $t"; done
for t in PostgreSQL Redis Gateway; do grep -qi -- "$t" architecture.md 2>/dev/null && pass "на схемах есть $t" || fail "на схемах нет $t"; done
has architecture.md "Rel(" && pass "показаны связи Rel(...)" || fail "нет связей Rel(...)"

echo "--- 3. Gateway (nginx.conf)"
N=gateway/nginx.conf
has $N "limit_req_zone" && pass "лимит запросов настроен"            || fail "нет limit_req_zone"
has $N "upstream "      && pass "есть upstream для реплик API"       || fail "нет upstream"
has $N "location /api/" && pass "маршрут /api/ ведёт в API"          || fail "нет location /api/"
has $N "X-Upstream"     && pass "заголовок X-Upstream для проверки"  || fail "нет заголовка X-Upstream"

echo "--- 4. docker-compose.yml"
for s in gateway api db redis; do svc $s | grep -q . && pass "сервис $s описан" || fail "нет сервиса $s"; done
svc gateway | grep -q "ports:"   && pass "у gateway опубликован порт"           || fail "у gateway нет ports"
svc api   | grep -q "ports:"     && fail "у api опубликован порт — API должен быть скрыт за gateway" || pass "api без ports (скрыт за gateway)"
svc db    | grep -q "ports:"     && fail "у db опубликован порт"   || pass "db без ports"
svc redis | grep -q "ports:"     && fail "у redis опубликован порт" || pass "redis без ports"
svc api   | grep -q "build:"     && fail "api собирается локально — нужен образ из Docker Hub" || pass "api без build"
svc api   | grep -Eq "image: .+/.+" && pass "api берётся из реестра: $(svc api | grep 'image:' | sed 's/^ *//')" || fail "у api нет образа вида ЛОГИН/имя:тег"
grep -A1 "^  backend:" docker-compose.yml | grep -q "internal: true" && pass "сеть backend внутренняя" || fail "сеть backend не internal"
svc redis | grep -q "healthcheck:" && pass "у redis есть healthcheck" || fail "у redis нет healthcheck"
grep -q "^\.env" .gitignore 2>/dev/null && pass ".env в .gitignore" || fail ".env не в .gitignore"
if git ls-files --error-unmatch .env >/dev/null 2>&1; then fail ".env попал в git"; else pass ".env не в git"; fi
grep -q "Password=[A-Za-z0-9]" docker-compose.yml && fail "пароль записан в docker-compose.yml открытым текстом" || pass "пароль не в docker-compose.yml"

echo "--- 5. Работающая система"
if [ -z "$(docker compose ps -q gateway 2>/dev/null)" ]; then
  fail "стек не запущен: выполните docker compose up -d --scale api=2"
else
  run=$(docker compose ps --services --status running 2>/dev/null | sort | tr '\n' ' ')
  info "запущены: $run"
  for s in gateway api db redis; do echo " $run" | grep -q " $s " && pass "$s работает" || fail "$s не работает"; done
  r=$(docker compose ps -q api 2>/dev/null | wc -l | tr -d ' ')
  [ "$r" -ge 2 ] && pass "реплик api: $r" || fail "реплик api: $r (нужно 2: --scale api=2)"
  c=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:8080/health)
  [ "$c" = "200" ] && pass "GET /health через gateway → 200" || fail "GET /health через gateway → $c"
  ups=""
  for i in 1 2 3 4 5 6 7 8; do
    u=$(curl -s -D - -o /dev/null --max-time 5 http://localhost:8080/health | grep -i "^x-upstream" | tr -d '\r' | cut -d' ' -f2)
    ups="$ups $u"
  done
  d=$(echo $ups | tr ' ' '\n' | sort -u | grep -c .)
  info "ответили экземпляры:$(echo $ups | tr ' ' '\n' | sort -u | tr '\n' ' ')"
  [ "$d" -ge 2 ] && pass "балансировка: ответили $d разных экземпляра" || fail "балансировка: ответил $d экземпляр"
  c=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:8080/admin)
  [ "$c" = "404" ] && pass "неизвестный маршрут /admin → 404" || fail "/admin → $c (ожидался 404)"
  codes=""; for i in $(seq 1 25); do codes="$codes $(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:8080/api/health)"; done
  echo "$codes" | grep -q 429 && pass "лимит запросов срабатывает (есть 429)" || fail "лимит не сработал: нет ответа 429"
  [ "$(docker compose exec -T redis redis-cli ping 2>/dev/null | tr -d '\r')" = "PONG" ] && pass "redis отвечает PONG" || fail "redis не отвечает"
fi

echo "=== Итого: $ok из $total ==="
