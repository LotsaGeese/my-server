FROM python:3.11-slim
WORKDIR /kolibri
RUN apt-get update && apt-get install -y \
    build-essential \
    gcc \
    curl \
    git \
&& rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir kolibri

EXPOSE 8080
ENV KOLIBRI_HOME=/kolibri/.kolibri

CMD ["kolibri", "start", "--foreground", "--port", "8080"]   
