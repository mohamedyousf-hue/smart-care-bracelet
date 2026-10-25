
import hashlib
import hmac
import os
import secrets
from datetime import datetime, timedelta, timezone
 
import jwt  # مكتبة pyjwt
from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field
from sqlalchemy import Column, DateTime, Float, Integer, String, create_engine
from sqlalchemy.orm import declarative_base, sessionmaker
 
# ---------- 1) الاتصال بقاعدة البيانات ----------
# XAMPP الافتراضي: المستخدم root وبدون كلمة سر
DATABASE_URL = os.environ.get(
    "DATABASE_URL", "mysql+pymysql://root:@127.0.0.1:3306/smartcare"
)
connect_args = {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {}
engine = create_engine(DATABASE_URL, connect_args=connect_args)
SessionLocal = sessionmaker(bind=engine)
Base = declarative_base()
 
 
# ---------- 2) الجداول ----------
class ReadingDB(Base):
    __tablename__ = "readings"
 
    id = Column(Integer, primary_key=True, autoincrement=True)
    device_id = Column(String(50), index=True)
    measured_at = Column(DateTime, index=True)
    heart_rate = Column(Float)
    spo2 = Column(Float)
    temperature = Column(Float)
    source = Column(String(20), default="simulator")
 
 
class UserDB(Base):
    __tablename__ = "users"
 
    id = Column(Integer, primary_key=True, autoincrement=True)
    name = Column(String(100))
    username = Column(String(50), unique=True, index=True)
    password_hash = Column(String(200))
    role = Column(String(20))                      # "patient" أو "caregiver"
    device_id = Column(String(50), nullable=True)  # للمريض: السوار بتاعه
    patient_id = Column(Integer, nullable=True)    # لمقدم الرعاية: المريض اللي بيتابعه
 
 
Base.metadata.create_all(engine)  # يعمل الجداول الناقصة بس
 
 
# ---------- 3) كلمات السر والتوكن ----------
SECRET_KEY = os.environ.get("SECRET_KEY", "dev-only-change-me")  # للتطوير فقط
ALGORITHM = "HS256"
TOKEN_HOURS = 12
 
 
def hash_password(password: str) -> str:
    salt = secrets.token_hex(16)
    h = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), 200_000)
    return f"{salt}${h.hex()}"
 
 
def verify_password(password: str, stored: str) -> bool:
    salt, h = stored.split("$")
    new = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), 200_000)
    return hmac.compare_digest(new.hex(), h)
 
 
def create_token(user: UserDB) -> str:
    payload = {
        "sub": str(user.id),
        "role": user.role,
        "exp": datetime.now(timezone.utc) + timedelta(hours=TOKEN_HOURS),
    }
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)
 
 
bearer = HTTPBearer()
 
 
def current_user(creds: HTTPAuthorizationCredentials = Depends(bearer)) -> dict:
    try:
        payload = jwt.decode(creds.credentials, SECRET_KEY, algorithms=[ALGORITHM])
    except jwt.PyJWTError:
        raise HTTPException(401, "تسجيل الدخول منتهي أو غير صالح")
    with SessionLocal() as db:
        user = db.get(UserDB, int(payload["sub"]))
        if user is None:
            raise HTTPException(401, "المستخدم غير موجود")
        return {
            "id": user.id,
            "name": user.name,
            "role": user.role,
            "device_id": user.device_id,
            "patient_id": user.patient_id,
        }
 
 
def patient_of(user: dict):
    """يرجّع (اسم المريض، جهازه) حسب دور المستخدم."""
    if user["role"] == "patient":
        return user["name"], user["device_id"]
    if user["patient_id"]:
        with SessionLocal() as db:
            p = db.get(UserDB, user["patient_id"])
            if p:
                return p.name, p.device_id
    return None, None
 
 
def device_for(user: dict) -> str:
    _, device = patient_of(user)
    if not device:
        raise HTTPException(404, "لا يوجد جهاز مرتبط بهذا الحساب")
    return device
 
 
# ---------- 4) شكل البيانات ----------
class ReadingIn(BaseModel):
    device_id: str
    measured_at: datetime
    heart_rate: float = Field(ge=20, le=250)
    spo2: float = Field(ge=50, le=100)
    temperature: float = Field(ge=30, le=45)
 
 
class LoginIn(BaseModel):
    username: str
    password: str
 
 
app = FastAPI(title="Smart Care Bracelet API")
 
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # للتطوير بس، هنقفله بعدين
    allow_methods=["*"],
    allow_headers=["*"],
)
 
 
def to_dict(r: ReadingDB):
    return {
        "device_id": r.device_id,
        "measured_at": r.measured_at.isoformat(),
        "heart_rate": r.heart_rate,
        "spo2": r.spo2,
        "temperature": r.temperature,
        "source": r.source,
    }
 
 
def get_history(device_id: str, limit: int):
    limit = max(1, min(limit, 500))
    with SessionLocal() as db:
        rows = (
            db.query(ReadingDB)
            .filter(ReadingDB.device_id == device_id)
            .order_by(ReadingDB.measured_at.desc())
            .limit(limit)
            .all()
        )
        return [to_dict(r) for r in reversed(rows)]  # من الأقدم للأحدث
 
 
# ---------- 5) المسارات ----------
@app.get("/")
def hello():
    return {"message": "Smart Care API شغال"}
 
 
# استقبال قراءة من السوار (مفتوح مؤقتًا للمحاكي؛ السوار الحقيقي هياخد مفتاح جهاز)
@app.post("/readings", status_code=201)
def add_reading(data: ReadingIn):
    t = data.measured_at
    if t.tzinfo is not None:
        t = t.astimezone(timezone.utc).replace(tzinfo=None)  # نخزّن بتوقيت UTC
 
    with SessionLocal() as db:
        row = ReadingDB(
            device_id=data.device_id,
            measured_at=t,
            heart_rate=data.heart_rate,
            spo2=data.spo2,
            temperature=data.temperature,
        )
        db.add(row)
        db.commit()
        db.refresh(row)
        return to_dict(row)
 
 
# تسجيل الدخول
@app.post("/auth/login")
def login(data: LoginIn):
    with SessionLocal() as db:
        user = db.query(UserDB).filter(UserDB.username == data.username).first()
        if user is None or not verify_password(data.password, user.password_hash):
            raise HTTPException(401, "اسم المستخدم أو كلمة السر غير صحيحة")
        return {
            "access_token": create_token(user),
            "role": user.role,
            "name": user.name,
        }
 
 
# بيانات المستخدم الحالي
@app.get("/me")
def me(user: dict = Depends(current_user)):
    patient_name, device = patient_of(user)
    return {
        "id": user["id"],
        "name": user["name"],
        "role": user["role"],
        "patient_name": patient_name,
        "device_id": device,
    }
 
 
# سجل قراءات المريض (المريض يشوف بتاعه، ومقدم الرعاية يشوف مريضه)
@app.get("/me/history")
def my_history(limit: int = 30, user: dict = Depends(current_user)):
    return get_history(device_for(user), limit)
 
 
def ensure_access(user: dict, device_id: str):
    if device_for(user) != device_id:
        raise HTTPException(403, "ليس لديك صلاحية على هذا الجهاز")
 
 
@app.get("/devices/{device_id}/latest")
def latest(device_id: str, user: dict = Depends(current_user)):
    ensure_access(user, device_id)
    rows = get_history(device_id, 1)
    if not rows:
        raise HTTPException(404, "لا توجد قراءات لهذا الجهاز")
    return rows[-1]
 
 
@app.get("/devices/{device_id}/history")
def device_history(device_id: str, limit: int = 30, user: dict = Depends(current_user)):
    ensure_access(user, device_id)
    return get_history(device_id, limit)
 