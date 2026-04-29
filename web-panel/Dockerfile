# Multistage build para reducir tamaño de imagen

# Stage 1: Builder
FROM python:3.11-slim as builder

WORKDIR /app

# Instalar dependencias del sistema
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Copiar requirements y instalar dependencias Python
COPY backend/requirements.txt .
RUN pip install --user --no-cache-dir -r requirements.txt

# Stage 2: Runtime
FROM python:3.11-slim

WORKDIR /app

# Instalar solo librerías runtime necesarias
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    && rm -rf /var/lib/apt/lists/*

# Copiar dependencias Python del builder
COPY --from=builder /root/.local /root/.local

# Agregar /root/.local/bin al PATH
ENV PATH=/root/.local/bin:$PATH

# Copiar código de la aplicación
COPY backend/ .

# Crear usuario no-root
RUN useradd -m -u 1000 appuser && chown -R appuser:appuser /app
USER appuser

# Comando por defecto: ejecutar servidor
CMD ["python", "manage.py", "runserver", "0.0.0.0:8000"]
