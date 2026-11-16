FROM python:3.12-slim

WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app

# Run as an unprivileged user.
RUN useradd --system --uid 10001 vaultsync && mkdir -p /data && chown vaultsync /data
USER vaultsync

EXPOSE 8080
# No access log: which addresses connect, and when, is exactly what the
# people using this need kept off a server's disk.
CMD ["uvicorn", "app.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8080", "--proxy-headers", "--no-access-log"]
