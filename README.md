# DevOps Architecture Project (КТ 5)

## Описание
Проект демонстрирует архитектуру с API Gateway (Nginx), двумя репликами API, PostgreSQL и Redis.

## Запуск
1. Заполните файл `.env` (на основе `.env.example`).
2. Запустите систему:
   docker compose up -d --scale api=2

## Проверка
- Здоровье: curl http://localhost:8080/health
- Балансировка: несколько раз выполните curl -I http://localhost:8080/health и посмотрите на X-Upstream.
- Создание задачи: curl -X POST http://localhost:8080/api/tasks -H "Content-Type: application/json" -d '{"title":"Test","done":false}'
