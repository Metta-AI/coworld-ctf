N_LIB_PRIVATE N_NIMCALL(NIM_BOOL, rayClear__OOZsrcZshellZbody95map_u423)(tyObject_BodyMapcolonObjectType___4y9bFm44KMLHzM8rkjGTWaQ* map_p0, tyTuple__1v9bKyksXWMsm0vNwmZ4EuQ a_p1, tyTuple__1v9bKyksXWMsm0vNwmZ4EuQ b_p2) {
	NIM_BOOL result;
	NI dx_1;
	NI TM__qjR89apTfyqEuUD60PFAIMQ_417;
	NI dy_1;
	NI TM__qjR89apTfyqEuUD60PFAIMQ_418;
	NI steps_1;
NIM_BOOL* nimErr_;
	nimfr_("rayClear", "body_map.nim");
{nimErr_ = nimErrorFlag();
	result = (NIM_BOOL)0;
	{
		NIM_BOOL T3_;
		NIM_BOOL T4_;
		NIM_BOOL T6_;
		T3_ = (NIM_BOOL)0;
		T4_ = (NIM_BOOL)0;
		T4_ = inBounds__OOZsrcZshellZbody95map_u415(map_p0, a_p1);
		if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
		T3_ = !(T4_);
		if (T3_) goto LA5_;
		T6_ = (NIM_BOOL)0;
		T6_ = inBounds__OOZsrcZshellZbody95map_u415(map_p0, b_p2);
		if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
		T3_ = !(T6_);
LA5_: ;
		if (!T3_) goto LA7_;
		result = NIM_FALSE;
		goto BeforeRet_;
	}
LA7_: ;
	if (nimSubInt(b_p2.Field0, a_p1.Field0, &TM__qjR89apTfyqEuUD60PFAIMQ_417)) { raiseOverflow(); goto BeforeRet_;
	};
	dx_1 = (NI)(TM__qjR89apTfyqEuUD60PFAIMQ_417);
	if (nimSubInt(b_p2.Field1, a_p1.Field1, &TM__qjR89apTfyqEuUD60PFAIMQ_418)) { raiseOverflow(); goto BeforeRet_;
	};
	dy_1 = (NI)(TM__qjR89apTfyqEuUD60PFAIMQ_418);
	if (dx_1 == (IL64(-9223372036854775807) - IL64(1))){ raiseOverflow(); goto BeforeRet_;
	}
	if (dy_1 == (IL64(-9223372036854775807) - IL64(1))){ raiseOverflow(); goto BeforeRet_;
	}
	steps_1 = (((dx_1 > 0? (dx_1) : -(dx_1)) >= (dy_1 > 0? (dy_1) : -(dy_1))) ? (dx_1 > 0? (dx_1) : -(dx_1)) : (dy_1 > 0? (dy_1) : -(dy_1)));
	{
		NIM_BOOL T13_;
		if (!(steps_1 == ((NI)0))) goto LA11_;
		T13_ = (NIM_BOOL)0;
		T13_ = isWall__OOZsrcZshellZbody95map_u419(map_p0, a_p1);
		if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
		result = !(T13_);
		goto BeforeRet_;
	}
LA11_: ;
	{
		NI step_1;
		NI res_1;
		step_1 = (NI)0;
		res_1 = ((NI)0);
		{
			while (1) {
				tyTuple__1v9bKyksXWMsm0vNwmZ4EuQ point_1;
				NI T17_;
				NI T18_;
				NI TM__qjR89apTfyqEuUD60PFAIMQ_419;
				if (!(res_1 <= steps_1)) goto LA16;
				step_1 = ((NI) (res_1));
				T17_ = (NI)0;
				T17_ = pyRound__OOZsrcZshellZbody95map_u124(((NF)(((NF) (a_p1.Field0))) + (NF)(((NF)(((NF)(((NF) (dx_1))) * (NF)(((NF) (step_1))))) / (NF)(((NF) (steps_1)))))));
				if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
				point_1.Field0 = T17_;
				T18_ = (NI)0;
				T18_ = pyRound__OOZsrcZshellZbody95map_u124(((NF)(((NF) (a_p1.Field1))) + (NF)(((NF)(((NF)(((NF) (dy_1))) * (NF)(((NF) (step_1))))) / (NF)(((NF) (steps_1)))))));
				if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
				point_1.Field1 = T18_;
				{
					NIM_BOOL T21_;
					T21_ = (NIM_BOOL)0;
					T21_ = isWall__OOZsrcZshellZbody95map_u419(map_p0, point_1);
					if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
					if (!T21_) goto LA22_;
					result = NIM_FALSE;
					goto BeforeRet_;
				}
LA22_: ;
				if (nimAddInt(res_1, ((NI)1), &TM__qjR89apTfyqEuUD60PFAIMQ_419)) { raiseOverflow(); goto BeforeRet_;
				};
				res_1 = (NI)(TM__qjR89apTfyqEuUD60PFAIMQ_419);
			} LA16: ;
		}
	}
	result = NIM_TRUE;
	}BeforeRet_: ;
	popFrame();
	return result;
}
