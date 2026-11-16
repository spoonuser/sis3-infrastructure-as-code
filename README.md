# SIS 3 — Infrastructure as Code

Учебный проект Cloud Application Development (KBTU), SIS 3.

## Что реализовано

- CloudFormation YAML как единый источник инфраструктуры.
- VPC с двумя public subnets; NAT Gateway не создаётся, чтобы не добавлять фиксированную почасовую стоимость.
- ECR repository с immutable image tags и lifecycle policy.
- ECS Fargate service за Application Load Balancer.
- Две ECS IAM роли: task execution role и task role.
- EventBridge custom bus → SQS → Lambda consumer.
- SQS Dead Letter Queue с `maxReceiveCount: 3`.
- DynamoDB conditional write для демонстрации idempotency.
- CloudWatch log groups с заданным retention period.

## Требования

- AWS account и разрешения для CloudFormation, EC2/VPC, IAM, ECR, ECS, ELB, Lambda, SQS, EventBridge, DynamoDB и CloudWatch.
- AWS CLI v2, Docker Desktop, Git.
- Регион по умолчанию: `us-east-1`.

> Не добавляйте AWS credentials, `.env` или секреты в Git. Для первоначального учебного запуска используйте только отдельную учебную AWS-учётную запись/роль, если она доступна. Не создавайте Root access keys ради этого проекта.

## Шаг 1. Проверить инструменты

```powershell
aws sts get-caller-identity
docker version
git --version
```

У `docker version` должны отображаться Client и Server. Если Server отсутствует, запустите Docker Desktop и дождитесь состояния Engine running.

## Шаг 2. Первый deploy — создать инфраструктуру и ECR

Запустите из корня репозитория:

```powershell
aws cloudformation deploy `
  --template-file infrastructure/template.yaml `
  --stack-name sis3-dev `
  --parameter-overrides Environment=dev ImageTag=bootstrap DesiredCount=0 `
  --capabilities CAPABILITY_IAM `
  --region us-east-1
```

На этом этапе `DesiredCount=0`: ECS service создан, но не пытается скачать ещё не загруженный image.

Получить URI ECR:

```powershell
aws cloudformation describe-stacks `
  --stack-name sis3-dev `
  --region us-east-1 `
  --query "Stacks[0].Outputs[?OutputKey=='EcrRepositoryUri'].OutputValue" `
  --output text
```

## Шаг 3. Собрать и отправить Docker image

Получить короткий Git SHA:

```powershell
git rev-parse --short HEAD
```

Задайте значения в PowerShell (замените URI и SHA на реальные):

```powershell
$ECR_URI = "ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/REPOSITORY"
$IMAGE_TAG = "YOUR_GIT_SHA"
```

Войти в ECR:

```powershell
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com
```

Собрать образ из папки `app`:

```powershell
docker build -t sis3-app:$IMAGE_TAG ./app
docker tag sis3-app:$IMAGE_TAG ${ECR_URI}:$IMAGE_TAG
docker push ${ECR_URI}:$IMAGE_TAG
```

В ECR включена неизменяемость тегов. Если ошибочно отправили неверный образ под этим тегом, нельзя перезаписать тот же тег: используйте новый Git SHA/tag.

## Шаг 4. Запустить ECS task

```powershell
aws cloudformation deploy `
  --template-file infrastructure/template.yaml `
  --stack-name sis3-dev `
  --parameter-overrides Environment=dev ImageTag=$IMAGE_TAG DesiredCount=1 `
  --capabilities CAPABILITY_IAM `
  --region us-east-1
```

Получить URL ALB:

```powershell
$ALB_DNS = aws cloudformation describe-stacks `
  --stack-name sis3-dev `
  --region us-east-1 `
  --query "Stacks[0].Outputs[?OutputKey=='AlbDnsName'].OutputValue" `
  --output text

Write-Host "http://$ALB_DNS/health"
```

Открой адрес в браузере. `/health` должен вернуть JSON со статусом `healthy`.

## Шаг 5. Отправить Domain Event

Получить имя EventBridge bus:

```powershell
$BUS = aws cloudformation describe-stacks `
  --stack-name sis3-dev `
  --region us-east-1 `
  --query "Stacks[0].Outputs[?OutputKey=='EventBusName'].OutputValue" `
  --output text
```

Приложение публикует событие через `POST /events`. Пример:

```powershell
$body = @{
  eventId = "sis3-demo-event-001"
  eventType = "OrderCreated"
  orderId = "order-001"
  message = "First SIS 3 test"
} | ConvertTo-Json

Invoke-RestMethod -Method Post -Uri "http://$ALB_DNS/events" -ContentType "application/json" -Body $body
```

Повторите запрос с тем же `eventId`. В CloudWatch Logs consumer должно быть видно `DUPLICATE ... skipped`. Новый `eventId` должен быть обработан как новое событие.

## Важное замечание об идемпотентности

Пример демонстрирует атомарный conditional write в DynamoDB и пропускает повторный eventId. Для production-системы бизнес-операция и фиксация idempotency key должны проектироваться атомарно (например, transactional write/outbox), чтобы исключить окно сбоя между записью ключа и выполнением бизнес-действия.

## Проверки перед защитой

1. `cfn-lint infrastructure/template.yaml`
2. CloudFormation stack status — `CREATE_COMPLETE` / `UPDATE_COMPLETE`.
3. ECR содержит image с конкретным immutable tag.
4. ECS task — `RUNNING`; ALB target — `healthy`.
5. `/health` возвращает HTTP 200.
6. EventBridge rule направляет события в SQS.
7. Consumer logs показывают `PROCESSED` и `DUPLICATE`.
8. CloudWatch log groups имеют retention.
9. Создать второй stack `sis3-repro` из чистого Git clone и проверить его Outputs и ECS health.

## Reproducibility test

В чистой копии репозитория используйте тот же доступный ECR image URI/tag и новый stack name:

```powershell
aws cloudformation deploy `
  --template-file infrastructure/template.yaml `
  --stack-name sis3-repro `
  --parameter-overrides Environment=dev ImageTag=YOUR_GIT_SHA DesiredCount=1 `
  --capabilities CAPABILITY_IAM `
  --region us-east-1
```

Поскольку ECR repository в первом стеке имеет имя, сгенерированное CloudFormation, второй стек использует собственный ECR repository. Поэтому перед запуском второго стека нужно повторить build/tag/push для URI второго стека. Используйте тот же Git SHA, но URI репозитория второго стека.

## Cleanup — удалить ресурсы после защиты

Сначала удостоверьтесь, что преподаватель больше не должен проверять развёрнутые стеки.

```powershell
aws cloudformation delete-stack --stack-name sis3-repro --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name sis3-repro --region us-east-1

aws cloudformation delete-stack --stack-name sis3-dev --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name sis3-dev --region us-east-1
```

Проверьте AWS Console: ECS, Load Balancers, NAT Gateways, ECR, CloudWatch, DynamoDB. Ресурсы с `Retain` (если добавите такую политику позже) могут остаться после удаления stack.

## Ограничения учебного шаблона

- ALB использует HTTP для учебной демонстрации. Не используйте такой endpoint для реальных пользовательских данных или production.
- ECS tasks размещаются в public subnets с публичным IP, но вход на контейнер разрешён только от ALB security group.
- Для production нужны HTTPS, WAF/ограничения входа, приватные subnets/NAT или VPC endpoints, более строгие IAM policies, alarm/monitoring и надёжная схема transactional idempotency.
- Перед реальным deploy проверьте стоимость ресурсов в выбранном регионе.
