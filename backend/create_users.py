"""يعمل حسابين تجريبيين: مريض ومقدم رعاية مرتبط بيه. شغّله مرة واحدة."""
from main import SessionLocal, UserDB, hash_password
with SessionLocal() as db:
    if db.query(UserDB).filter_by(username="ahmed").first():
        print("الحسابات موجودة بالفعل")
        raise SystemExit
 
    patient = UserDB(
        name="أحمد محمد",
        username="ahmed",
        password_hash=hash_password("ahmed123"),
        role="patient",
        device_id="bracelet_001",
    )
    db.add(patient)
    db.commit()
    db.refresh(patient)
 
    caregiver = UserDB(
        name="محمد أحمد",
        username="mohamed",
        password_hash=hash_password("mohamed123"),
        role="caregiver",
        patient_id=patient.id,
    )
    db.add(caregiver)
    db.commit()
    print("تم إنشاء الحسابين: ahmed / ahmed123  و  mohamed / mohamed123")